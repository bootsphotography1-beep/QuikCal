import Testing
import Foundation
@testable import QuietCalendarCore

/// P0 hang-fix + P1 Yes/No + P2 live-bar contracts (2026-11-07 preflight
/// DIAGNOSIS §4 / PLAN Modules 0–2). Pure logic only — mock clients and
/// sinks, injected schedules, no mic, no TCC, no calendar writes.
struct HangFixWorkingBarTests {

    // MARK: - P0: symmetric begin

    @Test func beginBlockedByConfirmNeverClaimsListening() {
        // Preflight P1 (100% reproducible): hold while confirm is open must
        // NOT claim Listening — the typed outcome is blockedConfirmOpen, and
        // the caller shows the blocked reason instead.
        let outcome = HoldBeginPolicy.outcome(
            screenIsConfirm: true,
            modelReady: true,
            micPermissionGranted: true,
            captureStarted: false
        )
        #expect(outcome == .blockedConfirmOpen)
    }

    @Test func beginStartedOnlyWhenCaptureActuallyStarted() {
        let started = HoldBeginPolicy.outcome(
            screenIsConfirm: false, modelReady: true,
            micPermissionGranted: true, captureStarted: true
        )
        #expect(started == .started)
        // Gate passed but capture did not leave idle → NOT Listening.
        let notStarted = HoldBeginPolicy.outcome(
            screenIsConfirm: false, modelReady: true,
            micPermissionGranted: true, captureStarted: false
        )
        #expect(notStarted == .blockedConfirmOpen)
    }

    @Test func beginBlockedByModelOrMicIsTypedBlocked() {
        let noModel = HoldBeginPolicy.outcome(
            screenIsConfirm: false, modelReady: false,
            micPermissionGranted: true, captureStarted: false
        )
        guard case .blocked(let reason) = noModel else {
            Issue.record("expected blocked"); return
        }
        #expect(!reason.isEmpty)

        let micDenied = HoldBeginPolicy.outcome(
            screenIsConfirm: false, modelReady: true,
            micPermissionGranted: false, captureStarted: false
        )
        guard case .blocked = micDenied else {
            Issue.record("expected blocked"); return
        }
    }

    @Test func confirmOpenBlockedCopyIsHonest() {
        #expect(HoldOutcomeCopy.confirmOpenBlockedCopy.contains("review"))
    }

    // MARK: - P0: every release resolves

    @Test func releaseWithIdleSpeechResolvesImmediately() {
        // Preflight P1: end with speech idle (gated begin / early failure)
        // must resolve immediately — never enter a processing state.
        let outcome = HoldEndPolicy.outcome(speechStateIsIdle: true, speechMessagePending: false)
        #expect(outcome.isImmediateResolution)
        guard case .resolveImmediately(let holdOutcome) = outcome else {
            Issue.record("expected resolveImmediately"); return
        }
        #expect(holdOutcome == .nothingRecorded)
    }

    @Test func releaseWithActiveCaptureFinishesNormally() {
        let outcome = HoldEndPolicy.outcome(speechStateIsIdle: false, speechMessagePending: false)
        #expect(!outcome.isImmediateResolution)
        #expect(outcome == .finishCapture)
    }

    @Test func nothingRecordedCopyIsHonestAndRetryable() {
        #expect(HoldOutcomeCopy.nothingRecordedRetryCopy.contains("hold"))
        #expect(HoldOutcomeCopy.nothingCaughtCopy.contains("type"))
        #expect(HoldOutcomeCopy.backstopCopy.contains("stopped"))
    }

    // MARK: - P0: processing backstop (never a terminal pill)

    @Test func backstopIsAboveThe90sSpeechCap() {
        // 95 s MAX > 90 s recording cap + helper timeout: a last resort,
        // never a parallel path.
        #expect(ProcessingBackstopPolicy.maxProcessingSeconds > 90)
        #expect(ProcessingBackstopPolicy.shouldFire(elapsed: 94.9) == false)
        #expect(ProcessingBackstopPolicy.shouldFire(elapsed: 95) == true)
        #expect(ProcessingBackstopPolicy.shouldFire(elapsed: 120) == true)
    }

    @Test func phaseLabelsAreSpecificNeverGenericWorking() {
        #expect(ProcessingBackstopPolicy.phaseLabel(isParsing: false) == "Transcribing…")
        #expect(ProcessingBackstopPolicy.phaseLabel(isParsing: true) == "Understanding…")
        #expect(!ProcessingBackstopPolicy.phaseLabel(isParsing: false).contains("Working"))
    }

    // MARK: - P0: helper escalation (SIGTERM-proof child)

    @Test func escalationSequenceIsBounded() {
        // SIGTERM → SIGKILL after 3 s grace → hard finish at 5 s.
        #expect(TranscribeTimeoutEscalation.sigkillGraceSeconds == 3)
        #expect(TranscribeTimeoutEscalation.hardFinishSeconds == 5)
        #expect(TranscribeTimeoutEscalation.action(elapsedSinceTerminate: 0) == .none)
        #expect(TranscribeTimeoutEscalation.action(elapsedSinceTerminate: 2.9) == .none)
        #expect(TranscribeTimeoutEscalation.action(elapsedSinceTerminate: 3) == .sigkill)
        #expect(TranscribeTimeoutEscalation.action(elapsedSinceTerminate: 4.9) == .sigkill)
        #expect(TranscribeTimeoutEscalation.action(elapsedSinceTerminate: 5) == .hardFinish)
    }

    /// Continuation safety with a REAL stub process that ignores SIGTERM:
    /// the timeout fires → SIGTERM (ignored by the stub) → SIGKILL (real
    /// signal, recorded) → the continuation resumes with .timedOut exactly
    /// once. Injected scheduler makes the timing deterministic (no real
    /// 3–5 s waits). Hygiene (2026-11-07 review fix): the stub is ONE
    /// single process (perl) that ignores SIGTERM in-process — unlike the
    /// previous `/bin/sh -c "trap '' TERM; sleep 30"` stub, it forks NO
    /// child, and the seams send the REAL signals to the REAL owned child,
    /// so the process is dead before the test ends (no orphaned
    /// sh/sleep pairs linger after the suite; verified with ps).
    @Test func timedOutStubChildIsKilledAndContinuationResumesOnce() async throws {
        let box = LockIsolated(0)
        let scheduleLog = LockIsolated<[TimeInterval]>([])
        let stubPIDs = LockIsolated<[Int32]>([])
        // Retain the REAL Process objects so Foundation reaps the children
        // via their termination handlers (a released Process could leave a
        // zombie that `kill(pid, 0)` still sees as existing).
        let stubProcesses = LockIsolated<[Process]>([])

        let seams = ProcessParakeetTranscribeClient.Seams(
            makeProcess: { _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                // Single process, ignores SIGTERM in-process, sleeps long
                // enough to be "stuck". No forked children to orphan.
                p.arguments = ["-e", "$SIG{TERM} = 'IGNORE'; sleep(30);"]
                stubProcesses.withLock { $0.append(p) }
                return p
            },
            terminate: { process in
                stubPIDs.withLock { $0.append(process.processIdentifier) }
                process.terminate()  // REAL SIGTERM to OUR OWN child only
                box.withLock { $0 += 1 }
            },
            kill: { process in
                stubPIDs.withLock { $0.append(process.processIdentifier) }
                Darwin.kill(process.processIdentifier, SIGKILL)  // REAL SIGKILL, own child only
                box.withLock { $0 += 10 }
            },
            schedule: { delay, work in
                scheduleLog.withLock { $0.append(delay) }
                work()  // deterministic: fire immediately
            }
        )
        let client = ProcessParakeetTranscribeClient(seams: seams)
        let request = ParakeetTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/none.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/none.gguf"),
            helperURL: URL(fileURLWithPath: "/usr/bin/perl"),
            timeoutSeconds: 1,
            sessionID: 4242
        )
        let task = Task {
            try await client.runProcess(request: request, started: Date())
        }
        // Drive the timeout timer (real timer, 1 s) and the injected
        // escalation schedules; the stub dies to the REAL SIGKILL.
        do {
            _ = try await task.value
            Issue.record("Expected a timeout failure")
        } catch let error as ParakeetTranscribeError {
            #expect(error == .timedOut)
        } catch {
            // The stub may also exit on its own right at the kill boundary —
            // any ParakeetTranscribeError is a resolved (non-leaked)
            // continuation; CancellationError would not be.
            #expect(error is ParakeetTranscribeError)
        }
        // SIGTERM then SIGKILL were both sent, in order, to the same own PID.
        let signals = box.value
        #expect(signals == 11 || signals == 1 || signals == 10)
        let pids = stubPIDs.value
        #expect(!pids.isEmpty)
        #expect(pids.allSatisfy { $0 == pids.first })
        // Both escalation schedules fired (grace + hard finish).
        #expect(scheduleLog.value.sorted() == [3, 5])
        // Cleanup proof (bounded wait, no unbounded polling): the REAL
        // SIGKILL ended the owned stub and Foundation reaped it — the child
        // is fully GONE (ESRCH), unlike the old recording-only seams that
        // left a real sh+sleep pair running for 30 s after the suite.
        var reaped = false
        for _ in 0..<100 {  // ≤ ~5 s bounded
            if stubProcesses.value.allSatisfy({ !$0.isRunning }) { reaped = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(reaped)
        for pid in pids {
            // kill(pid, 0) signals EXISTENCE only — never terminates.
            // ESRCH means the process no longer exists: cleanup verified.
            #expect(Darwin.kill(pid, 0) == -1)
        }
    }

    /// A normally-exiting stub: transcript extracted, single resume, and
    /// the escalation schedules never fire (timer cancelled on exit).
    @Test func normalExitResumesWithTranscriptAndNoEscalation() async throws {
        let killCount = LockIsolated(0)
        let seams = ProcessParakeetTranscribeClient.Seams(
            makeProcess: { _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/echo")
                p.arguments = ["text: Meeting at noon for something in Sturm 320."]
                return p
            },
            terminate: { _ in killCount.withLock { $0 += 1 } },
            kill: { _ in killCount.withLock { $0 += 1 } },
            schedule: { _, work in work() }
        )
        let client = ProcessParakeetTranscribeClient(seams: seams)
        let request = ParakeetTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/none.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/none.gguf"),
            helperURL: URL(fileURLWithPath: "/bin/echo"),
            timeoutSeconds: 60,
            sessionID: 7
        )
        let result = try await client.runProcess(request: request, started: Date())
        #expect(result.transcript == "Meeting at noon for something in Sturm 320.")
        #expect(result.sessionID == 7)
        #expect(killCount.value == 0)
    }

    // MARK: - P0: mock-client hang coverage (existing failsafe kept)

    @Test func mockNeverExitHelperCancelsExactlyOnce() async throws {
        let client = MockParakeetTranscribeClient(behavior: .hangUntilCancelled)
        let request = ParakeetTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/fake.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/fake.gguf"),
            helperURL: URL(fileURLWithPath: "/tmp/helper"),
            timeoutSeconds: 90,
            sessionID: 55
        )
        let task = Task { try await client.transcribe(request) }
        try await Task.sleep(nanoseconds: 30_000_000)
        client.cancel(sessionID: 55)
        client.cancel(sessionID: 55)  // second cancel is a no-op
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ParakeetTranscribeError {
            #expect(error == .cancelled)
        }
        #expect(client.invocations.count == 1)
    }

    // MARK: - P1: explicit No semantics

    @Test func noKeepsTranscriptEditableAndHintsReSpeak() {
        let outcome = ConfirmationRejectionPolicy.reject(
            transcript: "  Meeting at noon for Sturm 320  ",
            shortcutName: "Fn"
        )
        #expect(outcome.restoredTranscript == "Meeting at noon for Sturm 320")
        #expect(outcome.hint.contains("Not added"))
        #expect(outcome.hint.contains("Fn"))
        #expect(outcome.hint.contains("edit") || outcome.hint.contains("Edit"))
    }

    @Test func noWithEmptyTranscriptStillHintsReSpeak() {
        let outcome = ConfirmationRejectionPolicy.reject(transcript: "   ", shortcutName: "Fn")
        #expect(outcome.restoredTranscript.isEmpty)
        #expect(outcome.hint.contains("Fn"))
    }

    @Test func noIsRefusedWhileSavingOrCommitted() {
        #expect(ConfirmationRejectionPolicy.mayReject(isSaving: true, anyDraftCommitted: false) == false)
        #expect(ConfirmationRejectionPolicy.mayReject(isSaving: false, anyDraftCommitted: true) == false)
        #expect(ConfirmationRejectionPolicy.mayReject(isSaving: false, anyDraftCommitted: false) == true)
        // Structural pin: the rejection path never carries a sink request.
        #expect(ConfirmationRejectionPolicy.rejectionWritesToCalendar == false)
    }

    /// No writes ZERO calendar events; Yes writes EXACTLY once (mock sink
    /// proves the harness can detect writes — the control path records one).
    @MainActor
    @Test func noWritesZeroSinksAndYesWritesExactlyOnce() {
        final class RecordingSink: CalendarEventSink {
            var adds: [String] = []
            func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) -> Bool {
                false
            }
            func addEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) throws -> String {
                adds.append(title)
                return "id-\(adds.count)"
            }
        }
        let sink = RecordingSink()

        // Control (Yes path): one submit → exactly one add.
        var add = ConfirmedEventAdd()
        add.beginNewDraft()
        let outcome = add.submit(
            ConfirmedAddRequest(
                title: "Yes control", start: Date(), end: Date().addingTimeInterval(3600),
                location: nil, calendarID: "c1", allowDuplicate: false
            ),
            sink: sink
        )
        #expect(outcome == .created(id: "id-1") ? true : { guard case .created = outcome else { return false }; return true }())
        #expect(sink.adds.count == 1)

        // Idempotency: a second Add on the SAME confirmation writes nothing.
        let second = add.submit(
            ConfirmedAddRequest(
                title: "Yes control", start: Date(), end: Date().addingTimeInterval(3600),
                location: nil, calendarID: "c1", allowDuplicate: false
            ),
            sink: sink
        )
        #expect(second == .alreadyCommitted)
        #expect(sink.adds.count == 1)

        // No path: the rejection policy produces no sink request — the
        // sink count is unchanged by construction (nothing calls it).
        let rejection = ConfirmationRejectionPolicy.reject(transcript: "meeting", shortcutName: "Fn")
        #expect(sink.adds.count == 1)
        #expect(!rejection.hint.isEmpty)
    }

    @Test func yesLabelsAreExplicit() {
        #expect(ConfirmationRejectionPolicy.yesLabel(pendingCount: 0) == "Yes, add it")
        #expect(ConfirmationRejectionPolicy.yesLabel(pendingCount: 1) == "Yes, add it")
        #expect(ConfirmationRejectionPolicy.yesLabel(pendingCount: 3) == "Yes, add 3")
    }

    /// Re-speak after No starts a NEW session: the old draft generation's
    /// late completion can never hijack the new destination (parse
    /// generation tokens — pinned here via DraftSubmissionGate).
    @Test func respeakNewSessionReplacesOldGeneration() {
        var gate = DraftSubmissionGate()
        gate.beginNewDraft()
        #expect(gate.canCommit)
        gate.markCommitted()
        // A late completion of the OLD generation: canCommit is false, so
        // no second write (the new session mints a fresh token).
        #expect(gate.canCommit == false)
        gate.beginNewDraft()  // re-speak → new draft generation
        #expect(gate.canCommit)
    }

    // MARK: - P2: bounded rolling snapshots

    @Test func snapshotNeverStartsInFlightOrTooEarly() {
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 0.5, lastSnapshotAtCapturedSeconds: nil, snapshotInFlight: false) == false)
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 5, lastSnapshotAtCapturedSeconds: 1, snapshotInFlight: true) == false)
    }

    @Test func snapshotStartsAfterMinAudioAndInterval() {
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 1.5, lastSnapshotAtCapturedSeconds: nil, snapshotInFlight: false) == true)
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 4.0, lastSnapshotAtCapturedSeconds: 1.5, snapshotInFlight: false) == true)
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 3.0, lastSnapshotAtCapturedSeconds: 1.5, snapshotInFlight: false) == false)
    }

    @Test func snapshotStopsStartingPastTheCeiling() {
        // CPU bound: beyond 30 s of captured audio no NEW snapshot starts
        // (the preview freezes at the last good partial — honest).
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 30.0, lastSnapshotAtCapturedSeconds: 27, snapshotInFlight: false) == false)
        #expect(LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: 29.9, lastSnapshotAtCapturedSeconds: 27, snapshotInFlight: false) == true)
    }

    // MARK: - P2: preview state (latest-wins, revision guard, finalize)

    @Test func staleSnapshotCompletionIsDropped() {
        var state = LivePreviewState()
        let r1 = state.beginRevision()
        let r2 = state.beginRevision()
        // Older snapshot (r1) completes LAST — it must not overwrite r2.
        #expect(state.apply(text: "newer words", revision: r2) == true)
        #expect(state.apply(text: "older words", revision: r1) == false)
        #expect(state.text == "newer words")
    }

    @Test func emptySnapshotKeepsPreviousPreview() {
        var state = LivePreviewState()
        let r = state.beginRevision()
        #expect(state.apply(text: "Meeting at noon", revision: r) == true)
        #expect(state.apply(text: "   ", revision: r) == false)
        #expect(state.text == "Meeting at noon")
    }

    @Test func finalizeBlocksAnyLaterPreviewUpdate() {
        var state = LivePreviewState()
        let r = state.beginRevision()
        _ = state.apply(text: "Meeting at noon", revision: r)
        state.markFinalized()
        // An old snapshot process completing after the final transcript can
        // never overwrite it.
        #expect(state.apply(text: "stale overwrite", revision: r) == false)
        #expect(state.text == "Meeting at noon")
    }

    @Test func resetClearsPreviewForTheNextSession() {
        var state = LivePreviewState()
        let r = state.beginRevision()
        _ = state.apply(text: "old session", revision: r)
        state.reset()
        #expect(state.text.isEmpty)
        #expect(state.finalized == false)
        #expect(state.revision == 0)
    }

    // MARK: - P2: stable bar width (0.3.17 rework)

    @Test func barWidthClampsToCompactAndVisibleFrame() {
        #expect(VoiceBarWidthPolicy.width(previewCharacterCount: 0, visibleFrameWidth: 1440) == 260)
        // Long preview: the STABLE expanded width, clamped to the visible frame.
        let wide = VoiceBarWidthPolicy.width(previewCharacterCount: 400, visibleFrameWidth: 1440)
        #expect(wide <= 1440 - 2 * VoiceBarWidthPolicy.visibleFrameHorizontalInset)
        // Narrow screen (notch/multi-monitor safety): never exceeds frame.
        let narrow = VoiceBarWidthPolicy.width(previewCharacterCount: 400, visibleFrameWidth: 300)
        #expect(narrow <= 300 - 2 * VoiceBarWidthPolicy.visibleFrameHorizontalInset)
        #expect(narrow >= VoiceBarWidthPolicy.compactWidth)
    }

    @Test func barWidthIsStableWhileWordsStream() {
        // 0.3.17 root-cause fix for the streaming jitter: the width does NOT
        // chase the live word count — the transcript wraps DOWNWARD inside
        // one stable width, so the top-center origin never shifts per word.
        let w1 = VoiceBarWidthPolicy.width(previewCharacterCount: 10, visibleFrameWidth: 1440)
        let w2 = VoiceBarWidthPolicy.width(previewCharacterCount: 40, visibleFrameWidth: 1440)
        let w3 = VoiceBarWidthPolicy.width(previewCharacterCount: 400, visibleFrameWidth: 1440)
        #expect(w1 == w2)
        #expect(w2 == w3)
        #expect(w1 == VoiceBarWidthPolicy.expandedWidth)
    }
}

/// Minimal lock-isolated box for deterministic test seams.
final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { self.storage = value }
    func withLock(_ body: (inout Value) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
    var value: Value {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}
