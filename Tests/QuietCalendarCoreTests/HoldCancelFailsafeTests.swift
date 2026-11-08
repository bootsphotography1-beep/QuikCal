import Testing
import Foundation
@testable import QuietCalendarCore

// HOLD-CANCEL FAIL-SAFE (2026-11-07): the residual the parent overruled —
// if ALL listener paths die mid-hold, the pill is click-through and the
// recording continued until the next press or quit. These tests drive the
// REAL production pieces: the shared `HoldToTalkEventPipeline` (the exact
// type the AppKit monitor drives), the pure `HoldToTalkWatchdogPolicy`
// and the injectable `HoldToTalkHoldWatchdog` (fake clock + fake
// physical-key probe — never a real HID read, event tap, timer, mic or
// TCC), and the REAL decision policies (`HoldToTalkLaunchPolicy`,
// `VoiceOverlayPolicy`). Every loss path asserts: stop/cancel exactly 1,
// transcribe/submit exactly 0, and a clean recovery on the next fresh
// press cycle.
struct HoldCancelFailsafeTests {

    // MARK: - Helpers

    private func fnDown() -> HoldToTalkEventInterpreter.Decision {
        HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: HoldToTalkFnKeyCode,
            functionDown: true, optionDown: false, commandDown: false, controlDown: false
        )
    }

    private func fnUp() -> HoldToTalkEventInterpreter.Decision {
        HoldToTalkEventInterpreter.decision(
            shortcut: .fn, keyCode: HoldToTalkFnKeyCode,
            functionDown: false, optionDown: false, commandDown: false, controlDown: false
        )
    }

    /// Mutable box so closures can read live fixture state.
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Mock capture chain mirroring the AppDelegate wiring contract:
    /// begin → gate → mic start; end (trusted release) → stop →
    /// transcribe → submit; CANCEL (untrusted termination) → stop with NO
    /// transcription and NO submit. NEVER a real mic/transcription/calendar.
    private final class MockCaptureChain {
        var micStartCount = 0
        var micStopCount = 0
        var cancelStopCount = 0
        var submitted: [String] = []
        var endHoldCount = 0
        let modelReady: Bool
        let micGranted: Bool?

        init(modelReady: Bool = true, micGranted: Bool? = true) {
            self.modelReady = modelReady
            self.micGranted = micGranted
        }

        func begin() {
            switch VoiceOverlayPolicy.gate(modelReady: modelReady, micPermissionGranted: micGranted) {
            case .ready:
                micStartCount += 1
            case .blocked:
                break
            }
        }

        func end() {
            endHoldCount += 1
            guard micStartCount > micStopCount else { return }
            micStopCount += 1
            submitted.append("mock-transcript")
        }

        /// The CANCEL contract: the recording is terminated, NOTHING is
        /// transcribed or submitted.
        func cancel() {
            guard micStartCount > micStopCount + cancelStopCount else { return }
            cancelStopCount += 1
        }
    }

    private func makePipeline(
        shortcut: HoldToTalkShortcutKind = .fn,
        practice: Bool = false
    ) -> HoldToTalkEventPipeline {
        let pipeline = HoldToTalkEventPipeline(shortcut: shortcut)
        pipeline.setMonitoringEnabled(true)
        pipeline.practicePreviewOnly = practice
        return pipeline
    }

    /// Wires the pipeline exactly like AppKit monitor + AppDelegate:
    /// begin/end/cancel callbacks drive the mock chain; a watchdog
    /// (injectable clock + probe) cancels through the SAME
    /// `pipeline.cancelHold` path the monitor uses.
    private func makeWiredPipeline(
        practice: Bool = false
    ) -> (pipeline: HoldToTalkEventPipeline, chain: MockCaptureChain,
          cancels: Box<[HoldToTalkCancelReason]>) {
        let pipeline = makePipeline(practice: practice)
        let chain = MockCaptureChain()
        let cancels = Box<[HoldToTalkCancelReason]>([])
        pipeline.onBeginHold = { chain.begin() }
        pipeline.onEndHold = { chain.end() }
        pipeline.onCancelHold = { cancels.value.append($0); chain.cancel() }
        return (pipeline, chain, cancels)
    }

    // MARK: - Watchdog policy (pure decision table)

    @Test func watchdogPolicyMatrix() {
        let max = HoldToTalkWatchdogPolicy.maxHoldSeconds
        // Key physically down, inside the cap → keep watching.
        #expect(HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: max / 2, keyPhysicallyDown: true, consecutiveUpTicks: 0
        ) == .keepWatching)
        // Key reads UP but the debounce has not confirmed → keep watching.
        #expect(HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: 1, keyPhysicallyDown: false, consecutiveUpTicks: 1
        ) == .keepWatching)
        #expect(HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: 1, keyPhysicallyDown: false,
            consecutiveUpTicks: HoldToTalkWatchdogPolicy.releasedConfirmTicks - 1
        ) == .keepWatching)
        // Confirmed lost release (debounced) → CANCEL, never submit.
        #expect(HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: 1, keyPhysicallyDown: false,
            consecutiveUpTicks: HoldToTalkWatchdogPolicy.releasedConfirmTicks
        ) == .cancel(.lostRelease))
        // Cap elapsed — even with the key genuinely held → CANCEL, no
        // auto-submit.
        #expect(HoldToTalkWatchdogPolicy.action(
            elapsedSeconds: max, keyPhysicallyDown: true, consecutiveUpTicks: 0
        ) == .cancel(.maxDuration))
        // The cap is in the conservative ~60–120 s band, not tiny.
        #expect(max >= 60 && max <= 120)
    }

    // MARK: - Listener loss mid-hold cancels without submit

    @Test func fnListenerDeathMidHoldCancelsRecordingNotSubmit() {
        // Primary Fn listener dies mid-hold (the monitor's tap-death path
        // calls exactly pipeline.cancelHold(.listenerLost)).
        let (pipeline, chain, cancels) = makeWiredPipeline()
        pipeline.deliver(fnDown())
        #expect(chain.micStartCount == 1)

        pipeline.cancelHold(reason: .listenerLost)

        #expect(cancels.value == [.listenerLost])   // onCancelHold exactly once
        #expect(chain.cancelStopCount == 1)          // recording terminated
        #expect(chain.micStopCount == 0)             // NOT the release/stop path
        #expect(chain.submitted.isEmpty)             // NO transcribe/submit
        #expect(chain.endHoldCount == 0)             // onEndHold never fired
        #expect(pipeline.holdCancelCount == 1)
        #expect(pipeline.machine.phase == .idle)     // held state cleared
    }

    @Test func monitoringStopAndPermissionLossCancelLikeListenerLoss() {
        for reason in [HoldToTalkCancelReason.monitoringStopped, .permissionLost] {
            let (pipeline, chain, cancels) = makeWiredPipeline()
            pipeline.deliver(fnDown())
            pipeline.cancelHold(reason: reason)
            #expect(cancels.value == [reason], "\(reason): cancel fired once")
            #expect(chain.cancelStopCount == 1, "\(reason): recording terminated")
            #expect(chain.submitted.isEmpty, "\(reason): no submit")
            #expect(pipeline.machine.phase == .idle, "\(reason): state cleared")
        }
    }

    @Test func duplicateCancelIsIdempotentAndFiresCallbackExactlyOnce() {
        let (pipeline, chain, cancels) = makeWiredPipeline()
        pipeline.deliver(fnDown())
        pipeline.cancelHold(reason: .listenerLost)
        pipeline.cancelHold(reason: .listenerLost)   // duplicate
        pipeline.cancelHold(reason: .maxDuration)    // stale second cause

        #expect(cancels.value == [.listenerLost])    // exactly once, first reason
        #expect(pipeline.holdCancelCount == 1)
        #expect(chain.cancelStopCount == 1)
        #expect(chain.submitted.isEmpty)
    }

    @Test func cancelWithoutActiveHoldIsANoOp() {
        let (pipeline, chain, cancels) = makeWiredPipeline()
        pipeline.cancelHold(reason: .listenerLost)   // idle — nothing to cancel
        #expect(cancels.value.isEmpty)
        #expect(chain.cancelStopCount == 0)
        #expect(pipeline.holdCancelCount == 0)
    }

    // MARK: - Watchdog: lost release (physically up, no event)

    @Test func watchdogDebouncesThenCancelsLostRelease() {
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let keyDown = Box(true)
        var cancels: [HoldToTalkCancelReason] = []
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { keyDown.value },
            onCancel: { cancels.append($0) }
        )

        watchdog.holdBegan()
        #expect(watchdog.isActive)

        // The release event is lost; the physical key reads UP.
        keyDown.value = false
        for (offset, expectCancel) in [(0.2, false), (0.4, false), (0.6, true)] {
            clock.value = Date(timeIntervalSince1970: 1_000 + offset)
            watchdog.tick()
            if expectCancel {
                #expect(cancels == [.lostRelease])   // confirmed on the debounced tick
            } else {
                #expect(cancels.isEmpty, "tick at \(offset)s must still debounce")
            }
        }
        #expect(!watchdog.isActive)                  // window closed before callback

        // Phantom late tick — no double cancel.
        watchdog.tick()
        #expect(cancels == [.lostRelease])
    }

    @Test func watchdogCapsRecordingAtMaxDurationWhileKeyHeld() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        var cancels: [HoldToTalkCancelReason] = []
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { true },             // key held the whole time
            onCancel: { cancels.append($0) }
        )
        watchdog.holdBegan()
        let max = HoldToTalkWatchdogPolicy.maxHoldSeconds
        var cancelled = false
        for seconds in stride(from: 0.2, through: max + 1, by: 0.2) {
            clock.value = Date(timeIntervalSince1970: seconds)
            watchdog.tick()
            if !watchdog.isActive {
                cancelled = true
                break
            }
        }
        #expect(cancelled)
        #expect(cancels == [.maxDuration])          // cap cancels, never auto-submits
    }

    @Test func watchdogDoubleBeginCountsAsOneWindow() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        let keyDown = Box(false)   // phantom: reads up immediately
        var cancels: [HoldToTalkCancelReason] = []
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { keyDown.value },
            onCancel: { cancels.append($0) }
        )
        watchdog.holdBegan()
        watchdog.holdBegan()       // duplicate delivery (tap + NSEvent)
        for offset in [0.2, 0.4, 0.6] {
            clock.value = Date(timeIntervalSince1970: offset)
            watchdog.tick()
        }
        #expect(cancels == [.lostRelease])   // one window, one cancel
    }

    @Test func watchdogIsInactiveOutsideHold() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        var cancels: [HoldToTalkCancelReason] = []
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { false },
            onCancel: { cancels.append($0) }
        )
        // No hold began — ticks are no-ops.
        watchdog.tick()
        watchdog.tick()
        #expect(!watchdog.isActive)
        #expect(cancels.isEmpty)
        // After holdEnded, ticks stay no-ops.
        watchdog.holdBegan()
        watchdog.holdEnded()
        watchdog.tick()
        #expect(cancels.isEmpty)
    }

    @Test func normalReleaseBeforeWatchdogKeepsTrustedSubmitPath() {
        let (pipeline, chain, _) = makeWiredPipeline()
        let clock = Box(Date(timeIntervalSince1970: 0))
        var cancels: [HoldToTalkCancelReason] = []
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { false },   // key up — release ALREADY happened
            onCancel: { pipeline.cancelHold(reason: $0); cancels.append($0) }
        )

        pipeline.deliver(fnDown())
        watchdog.holdBegan()
        // Real release arrives BEFORE any watchdog probe could confirm a
        // lost release — the trusted path must stay intact.
        pipeline.deliver(fnUp())
        watchdog.holdEnded()               // monitor closes the window on release

        #expect(chain.micStartCount == 1)
        #expect(chain.micStopCount == 1)
        #expect(chain.submitted == ["mock-transcript"])
        #expect(cancels.isEmpty)
        #expect(pipeline.holdCancelCount == 0)
        // Late phantom ticks after release cancel nothing.
        watchdog.tick()
        #expect(cancels.isEmpty)
    }

    // MARK: - Watchdog → pipeline integration (the monitor's wiring)

    @Test func watchdogLostReleaseCancelsRealPipelineWithoutSubmit() {
        let (pipeline, chain, cancels) = makeWiredPipeline()
        let clock = Box(Date(timeIntervalSince1970: 0))
        let keyDown = Box(true)
        // The monitor wires the watchdog's cancel through the SAME
        // pipeline cancel path (cancelActiveHold → pipeline.cancelHold).
        let watchdog = HoldToTalkHoldWatchdog(
            now: { clock.value },
            keyPhysicallyDown: { keyDown.value },
            onCancel: { pipeline.cancelHold(reason: $0) }
        )

        pipeline.deliver(fnDown())
        watchdog.holdBegan()
        keyDown.value = false               // release event lost, key physically up
        for offset in [0.2, 0.4, 0.6] {     // three consecutive up probes
            clock.value = Date(timeIntervalSince1970: offset)
            watchdog.tick()                 // debounced confirmation on the 3rd
        }

        #expect(cancels.value == [.lostRelease])
        #expect(chain.cancelStopCount == 1) // recording terminated
        #expect(chain.submitted.isEmpty)    // NO transcribe/submit
        #expect(pipeline.machine.phase == .idle)
        #expect(pipeline.holdCancelCount == 1)
    }

    // MARK: - Stale async work after cancel never records or submits

    @Test func lateReleaseAndMicGrantAfterCancelNeverRecordOrSubmit() {
        let (pipeline, chain, cancels) = makeWiredPipeline()
        pipeline.deliver(fnDown())
        pipeline.cancelHold(reason: .listenerLost)
        #expect(cancels.value == [.listenerLost])

        // A LATE release event (delivered by a still-surviving listener)
        // must be a no-op: no onEndHold, no stop-and-transcribe, no submit.
        pipeline.deliver(fnUp())
        #expect(chain.endHoldCount == 0)
        #expect(chain.micStopCount == 0)
        #expect(chain.submitted.isEmpty)

        // A DELAYED MIC GRANT returning after the cancel must not start a
        // recording — the AppDelegate guard re-checks the live phase
        // (finishHoldMicRequest → shouldContinueHoldAfterMicGrant).
        let holdStillActive = pipeline.machine.phase == .holding
        let continues = HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: holdStillActive,
            keyPhysicallyDown: true,        // user may still physically hold
            screenSafeForCapture: true,
            speechIdle: true
        )
        #expect(!continues)                 // blocked pill, no begin
        #expect(chain.micStartCount == 1)    // only the ORIGINAL hold began
    }

    @Test func repairReinstallDoesNotRestartRecordingWhileUserStillHolds() {
        // Check again reinstalls the listener set mid-hold: the monitor
        // CANCELS the hold (listener loss), reinstalls, and the still-held
        // key must NOT auto-restart recording — a fresh press cycle is
        // required.
        let (pipeline, chain, cancels) = makeWiredPipeline()
        pipeline.deliver(fnDown())
        #expect(chain.micStartCount == 1)

        // Reinstall = stop (cancel) then start again (the pipeline-level
        // effects of startMonitoringIfPermitted).
        pipeline.cancelHold(reason: .listenerLost)
        pipeline.setMonitoringEnabled(false)
        pipeline.forceIdle()
        pipeline.setMonitoringEnabled(true)

        #expect(cancels.value == [.listenerLost])
        #expect(chain.cancelStopCount == 1)
        #expect(chain.submitted.isEmpty)

        // The user (still holding) releases — a release without a press
        // is a no-op: no submit, no callback.
        pipeline.deliver(fnUp())
        #expect(chain.endHoldCount == 0)
        #expect(chain.submitted.isEmpty)

        // The NEXT fresh press/release cycle works normally — exactly one
        // full trusted cycle after the repair.
        pipeline.deliver(fnDown())
        pipeline.deliver(fnUp())
        #expect(chain.micStartCount == 2)   // original + fresh
        #expect(chain.micStopCount == 1)    // only the fresh cycle submitted
        #expect(chain.submitted == ["mock-transcript"])
        #expect(pipeline.holdCancelCount == 1)  // still just the one cancel
    }

    // MARK: - Practice preview: cancel clears state, no capture

    @Test func practiceCancelClearsPracticePhaseWithoutCapture() {
        let (pipeline, chain, cancels) = makeWiredPipeline(practice: true)
        pipeline.deliver(fnDown())
        #expect(pipeline.practicePhase == .holding)
        #expect(chain.micStartCount == 0)   // practice never starts the mic

        pipeline.cancelHold(reason: .listenerLost)

        #expect(pipeline.practicePhase == .idle)
        #expect(cancels.value == [.listenerLost])  // host hides the pill
        #expect(chain.micStartCount == 0)
        #expect(chain.submitted.isEmpty)
        #expect(pipeline.holdCancelCount == 1)
    }

    // MARK: - Honest cancel copy

    @Test func cancelCopyIsHonestPerReason() {
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .listenerLost)
                == "Shortcut disconnected. Recording stopped.")
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .permissionLost)
                .contains("Accessibility"))
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .monitoringStopped)
                .contains("turned off"))
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .lostRelease)
                .contains("Recording stopped"))
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .maxDuration)
                .contains("safety limit"))
        // No pill while quitting.
        #expect(VoiceOverlayPolicy.holdCancelCopy(for: .appTerminating).isEmpty)
        // Every non-terminating copy says the recording STOPPED.
        for reason in [HoldToTalkCancelReason.listenerLost, .permissionLost,
                       .monitoringStopped, .lostRelease, .maxDuration] {
            #expect(VoiceOverlayPolicy.holdCancelCopy(for: reason)
                .contains("Recording stopped"))
        }
    }
}
