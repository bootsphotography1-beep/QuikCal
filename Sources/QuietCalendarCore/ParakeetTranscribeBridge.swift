import Foundation

/// Errors from the app-owned Parakeet helper path (never cloud speech).
public enum ParakeetTranscribeError: Error, Equatable, Sendable {
    case helperMissing(String)
    case modelNotReady(ParakeetModelReadiness)
    case audioMissing(String)
    case timedOut
    case cancelled
    case helperFailed(exitCode: Int32, stderr: String)
    case emptyTranscript
    case invalidOutput(String)

    public var userFacingMessage: String {
        switch self {
        case .helperMissing:
            return "Speech helper is missing from the app bundle. Rebuild QuikCal."
        case .modelNotReady(let readiness):
            return readiness.userFacingStatus
        case .audioMissing:
            return "No audio was captured. Try again or type."
        case .timedOut:
            return "Local Parakeet transcription timed out. Try a shorter note or type."
        case .cancelled:
            return "Transcription cancelled."
        case .helperFailed(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Local Parakeet helper failed. You can still type."
            }
            return "Local Parakeet helper failed: \(trimmed.prefix(160))"
        case .emptyTranscript:
            return "Didn't catch that — try again or type."
        case .invalidOutput:
            return "Local Parakeet returned unusable text. You can still type."
        }
    }
}

public struct ParakeetTranscribeRequest: Sendable, Equatable {
    public var audioURL: URL
    public var modelURL: URL
    public var helperURL: URL
    public var timeoutSeconds: TimeInterval
    public var sessionID: Int

    public init(
        audioURL: URL,
        modelURL: URL,
        helperURL: URL,
        timeoutSeconds: TimeInterval = 60,
        sessionID: Int
    ) {
        self.audioURL = audioURL
        self.modelURL = modelURL
        self.helperURL = helperURL
        self.timeoutSeconds = timeoutSeconds
        self.sessionID = sessionID
    }
}

public struct ParakeetTranscribeResult: Sendable, Equatable {
    public var transcript: String
    public var sessionID: Int
    public var durationSeconds: TimeInterval

    public init(transcript: String, sessionID: Int, durationSeconds: TimeInterval) {
        self.transcript = transcript
        self.sessionID = sessionID
        self.durationSeconds = durationSeconds
    }
}

/// App-level Parakeet bridge. Implementations must only kill their own helper process on cancel.
public protocol ParakeetTranscribeClient: Sendable {
    func transcribe(_ request: ParakeetTranscribeRequest) async throws -> ParakeetTranscribeResult
    func cancel(sessionID: Int)
}

/// Resolves the bundled helper and Application Support model for the running app / tests.
public enum ParakeetRuntimeLocator: Sendable {
    public static let helperFileName = "QuietCalendarTranscribe"
    public static let helperRelativeBundlePath = "SpeechRuntime/QuietCalendarTranscribe"

    public static func helperURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        if let url = bundle.url(
            forResource: "QuietCalendarTranscribe",
            withExtension: nil,
            subdirectory: "SpeechRuntime"
        ), fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        if let res = bundle.resourceURL {
            let candidate = res.appendingPathComponent("SpeechRuntime/\(helperFileName)")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func resolveModelURL(
        overridePath: String?,
        fileManager: FileManager = .default
    ) -> URL {
        if let overridePath, !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath)
        }
        return ParakeetModelStore.defaultModelURL(fileManager: fileManager)
    }
}

/// Tiny mutex usable from async contexts (avoids NSLock async unavailability).
private final class BoxLock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()

    init() {
        pthread_mutex_init(&mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(&mutex)
    }

    func withLock<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        return body()
    }
}

/// Pure escalation policy for a helper that ignores SIGTERM (P0 hang fix,
/// 2026-11-07 — preflight DIAGNOSIS §2 P3: the 90 s timer only sent
/// SIGTERM, so a surviving child leaked the checked continuation forever).
///
/// Sequence after the timeout fires: SIGTERM → after `sigkillGraceSeconds`
/// SIGKILL (only our own child process) → after `hardFinishSeconds` the
/// continuation resumes with the timeout error ANYWAY (single-resume is
/// guaranteed by the `didFinish` gate — the continuation can never leak).
public enum TranscribeTimeoutEscalation: Sendable {
    /// Grace between SIGTERM and SIGKILL.
    public static let sigkillGraceSeconds: TimeInterval = 3
    /// Hard ceiling after the timeout fired — resume regardless.
    public static let hardFinishSeconds: TimeInterval = 5

    public enum Action: Equatable, Sendable {
        case none
        case sigkill
        case hardFinish
    }

    /// The next escalation action for a process that still has not exited,
    /// given the time elapsed since SIGTERM was sent.
    public static func action(elapsedSinceTerminate: TimeInterval) -> Action {
        if elapsedSinceTerminate >= hardFinishSeconds { return .hardFinish }
        if elapsedSinceTerminate >= sigkillGraceSeconds { return .sigkill }
        return .none
    }
}

/// Process-run flags shared between the timeout timer and the escalation
/// schedule (file scope so the escalation helper can reference the type).
final class TranscribeRunFlags: @unchecked Sendable {
    var didFinish = false
    var timedOut = false
}

/// Process-backed client that invokes the bundled `QuietCalendarTranscribe` CLI.
public final class ProcessParakeetTranscribeClient: ParakeetTranscribeClient, @unchecked Sendable {
    private let box = BoxLock()
    private var processes: [Int: Process] = [:]

    /// Test seams (unit tests inject a stub process + manual scheduler;
    /// production defaults build the real helper invocation and use real
    /// signals). The seams are only reached AFTER `transcribe`'s
    /// model/helper/audio validation in production.
    public struct Seams: Sendable {
        public var makeProcess: @Sendable (ParakeetTranscribeRequest) -> Process
        public var terminate: @Sendable (Process) -> Void
        public var kill: @Sendable (Process) -> Void
        /// Schedules `work` after `delay` seconds on a background queue.
        public var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

        public init(
            makeProcess: @escaping @Sendable (ParakeetTranscribeRequest) -> Process = ProcessParakeetTranscribeClient.makeHelperProcess,
            terminate: @escaping @Sendable (Process) -> Void = { $0.terminate() },
            kill: @escaping @Sendable (Process) -> Void = { process in Darwin.kill(process.processIdentifier, SIGKILL) },
            schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
            }
        ) {
            self.makeProcess = makeProcess
            self.terminate = terminate
            self.kill = kill
            self.schedule = schedule
        }
    }

    private let seams: Seams

    public init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Builds the real helper invocation (the production default seam).
    public static func makeHelperProcess(_ request: ParakeetTranscribeRequest) -> Process {
        let process = Process()
        process.executableURL = request.helperURL
        process.arguments = [
            "-m", request.modelURL.path,
            "-q",
            "--timestamps", "none",
            "--backend", "metal",
            request.audioURL.path
        ]
        return process
    }

    public func cancel(sessionID: Int) {
        let process = box.withLock { () -> Process? in
            processes.removeValue(forKey: sessionID)
        }
        guard let process else { return }
        if process.isRunning {
            seams.terminate(process)
            // SIGTERM-proof child on a user/task cancel: escalate to
            // SIGKILL after the same grace so the terminationHandler (and
            // with it the continuation) always fires.
            seams.schedule(TranscribeTimeoutEscalation.sigkillGraceSeconds) { [seams] in
                if process.isRunning {
                    seams.kill(process)
                }
            }
        }
    }

    /// Escalate a stuck child: SIGTERM (already sent by the caller) →
    /// SIGKILL after the grace → hard-finish the continuation after the
    /// ceiling so it can never leak. Only THIS session's own child is ever
    /// signalled; the single-resume `didFinish` gate makes the hard finish
    /// safe even if the child later exits.
    private func escalateStuckChild(
        process: Process,
        gate: BoxLock,
        flags: TranscribeRunFlags,
        finish: @escaping @Sendable (Result<ParakeetTranscribeResult, Error>) -> Void
    ) {
        seams.schedule(TranscribeTimeoutEscalation.sigkillGraceSeconds) { [seams] in
            if process.isRunning {
                seams.kill(process)
            }
        }
        seams.schedule(TranscribeTimeoutEscalation.hardFinishSeconds) {
            let alreadyFinished = gate.withLock { flags.didFinish }
            if !alreadyFinished {
                finish(.failure(ParakeetTranscribeError.timedOut))
            }
        }
    }

    public func transcribe(_ request: ParakeetTranscribeRequest) async throws -> ParakeetTranscribeResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: request.helperURL.path) else {
            throw ParakeetTranscribeError.helperMissing(request.helperURL.path)
        }
        let modelCheck = ParakeetModelValidator.validate(
            fileURL: request.modelURL,
            requireChecksum: false,
            fileManager: fm
        )
        guard modelCheck.readiness == .ready else {
            throw ParakeetTranscribeError.modelNotReady(modelCheck.readiness)
        }
        guard fm.fileExists(atPath: request.audioURL.path) else {
            throw ParakeetTranscribeError.audioMissing(request.audioURL.path)
        }

        let started = Date()
        return try await withTaskCancellationHandler {
            try await runProcess(request: request, started: started)
        } onCancel: { [self] in
            self.cancel(sessionID: request.sessionID)
        }
    }

    /// Internal so @testable unit tests can exercise the process/pipe/
    /// escalation machinery directly with a stub process, bypassing only
    /// the file-validation preconditions (which production always runs
    /// via `transcribe` first).
    func runProcess(
        request: ParakeetTranscribeRequest,
        started: Date
    ) async throws -> ParakeetTranscribeResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ParakeetTranscribeResult, Error>) in
            let process = seams.makeProcess(request)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let gate = BoxLock()
            let flags = TranscribeRunFlags()
            let finish: @Sendable (Result<ParakeetTranscribeResult, Error>) -> Void = { result in
                let shouldResume = gate.withLock { () -> Bool in
                    if flags.didFinish { return false }
                    flags.didFinish = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            box.withLock {
                processes[request.sessionID] = process
            }

            let timeout = max(1, request.timeoutSeconds)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self, seams] in
                gate.withLock { flags.timedOut = true }
                // Remove from the session map and SIGTERM our own child;
                // then escalate (SIGKILL +3 s, hard finish +5 s) so the
                // continuation can never leak on a SIGTERM-proof child.
                self?.box.withLock {
                    _ = self?.processes.removeValue(forKey: request.sessionID)
                }
                if process.isRunning {
                    seams.terminate(process)
                }
                self?.escalateStuckChild(process: process, gate: gate, flags: flags, finish: finish)
            }
            timer.resume()

            process.terminationHandler = { [weak self] proc in
                timer.cancel()
                self?.box.withLock {
                    _ = self?.processes.removeValue(forKey: request.sessionID)
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                let wasTimedOut = gate.withLock { flags.timedOut }

                if Task.isCancelled {
                    finish(.failure(ParakeetTranscribeError.cancelled))
                    return
                }
                if wasTimedOut {
                    finish(.failure(ParakeetTranscribeError.timedOut))
                    return
                }
                if proc.terminationReason == .uncaughtSignal {
                    finish(.failure(ParakeetTranscribeError.cancelled))
                    return
                }
                if proc.terminationStatus != 0 {
                    finish(.failure(
                        ParakeetTranscribeError.helperFailed(
                            exitCode: proc.terminationStatus,
                            stderr: errText
                        )
                    ))
                    return
                }

                let transcript = ProcessParakeetTranscribeClient.extractTranscript(from: outText)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    finish(.failure(ParakeetTranscribeError.emptyTranscript))
                    return
                }
                finish(.success(
                    ParakeetTranscribeResult(
                        transcript: trimmed,
                        sessionID: request.sessionID,
                        durationSeconds: Date().timeIntervalSince(started)
                    )
                ))
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                box.withLock {
                    _ = processes.removeValue(forKey: request.sessionID)
                }
                finish(.failure(
                    ParakeetTranscribeError.helperFailed(
                        exitCode: -1,
                        stderr: error.localizedDescription
                    )
                ))
            }
        }
    }

    /// Parses bundled `QuietCalendarTranscribe` / `transcribe-cli` stdout.
    ///
    /// Real `-q` output ends with a metadata line `text: <transcript>` (see
    /// `examples/cli/asr.cpp`). Strip **only** that helper key prefix — never
    /// the dictated word "text" inside the value (e.g. `text: text message…`
    /// → `text message…`). Blank / `(empty)` / diagnostics-only → `""`
    /// (caller maps to `.emptyTranscript`).
    public static func extractTranscript(from stdout: String) -> String {
        let rawLines = stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        // Prefer the official `text:` key (column-0), matching upstream validate.py.
        // Walk indices manually (EnumeratedSequence.last(where:) needs newer macOS).
        var textIndex: Int?
        for idx in rawLines.indices.reversed() {
            if Self.isTextMetadataLine(rawLines[idx]) {
                textIndex = idx
                break
            }
        }
        if let textIndex {
            var value = Self.stripTextMetadataPrefix(rawLines[textIndex])
            if value == "(empty)" { return "" }

            // Multiline: transcript may embed newlines inside printf("%s").
            // Collect following non-diagnostic continuations until the next helper key.
            var i = textIndex + 1
            while i < rawLines.count {
                let next = rawLines[i]
                if Self.isHelperDiagnosticLine(next) { break }
                if Self.isTextMetadataLine(next) { break }
                // Trailing blank after transcript is not content.
                if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   i + 1 < rawLines.count,
                   Self.isHelperDiagnosticLine(rawLines[i + 1]) {
                    break
                }
                value += "\n" + next
                i += 1
            }

            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Legacy / bare-line fallback (unit fixtures without `text:` key).
        let candidates = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isHelperDiagnosticLine($0) }
        return candidates.last ?? ""
    }

    /// True for the helper's transcript metadata line (`text: …`), not bare dictation.
    private static func isTextMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Require the colon form used by the CLI — do not treat "text foo" as metadata.
        return trimmed.lowercased().hasPrefix("text:")
    }

    private static func stripTextMetadataPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let idx = trimmed.firstIndex(of: ":") else { return trimmed }
        var value = String(trimmed[trimmed.index(after: idx)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    /// Helper diagnostic / status lines that must never become the note title.
    private static func isHelperDiagnosticLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()

        // Indented nested keys under audio:/model:/text: blocks.
        let nestedKeys = [
            "samples:", "duration:", "sample rate", "backend:", "name:",
            "license:", "max audio:", "realtime:", "note:", "revision:"
        ]
        if nestedKeys.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let topKeys = [
            "audio:", "model:", "run:", "load:", "system:", "tokens:",
            "segments:", "segment:", "detected-language:", "language:",
            "parakeet:", "whisper_", "ggml_", "speaker segments:",
            "finalize:", "error:"
        ]
        if topKeys.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        // Explicit text: metadata is handled separately; treat as diagnostic here
        // so legacy fallback never returns the raw `text: …` line.
        if lower.hasPrefix("text:") { return true }
        return false
    }
}

/// Deterministic mock for unit tests (no Process / no mic).
public final class MockParakeetTranscribeClient: ParakeetTranscribeClient, @unchecked Sendable {
    public enum Behavior: Sendable {
        case transcript(String)
        case failure(ParakeetTranscribeError)
        case hangUntilCancelled
    }

    private let box = BoxLock()
    private var canceledSessions = Set<Int>()
    public private(set) var invocations: [ParakeetTranscribeRequest] = []
    public var behavior: Behavior

    public init(behavior: Behavior = .transcript("Meeting at noon")) {
        self.behavior = behavior
    }

    public func cancel(sessionID: Int) {
        box.withLock { () -> Void in
            canceledSessions.insert(sessionID)
        }
    }

    public func transcribe(_ request: ParakeetTranscribeRequest) async throws -> ParakeetTranscribeResult {
        box.withLock { invocations.append(request) }
        try Task.checkCancellation()
        switch behavior {
        case .transcript(let text):
            let canceled = box.withLock { canceledSessions.contains(request.sessionID) }
            if canceled { throw ParakeetTranscribeError.cancelled }
            return ParakeetTranscribeResult(
                transcript: text,
                sessionID: request.sessionID,
                durationSeconds: 0.01
            )
        case .failure(let error):
            throw error
        case .hangUntilCancelled:
            while true {
                try Task.checkCancellation()
                let canceled = box.withLock { canceledSessions.contains(request.sessionID) }
                if canceled { throw ParakeetTranscribeError.cancelled }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

/// Pure policy: hold-to-talk must not start mic / listening resize while confirmation is open.
public enum HoldToTalkConfirmPolicy: Sendable {
    public static func shouldBeginCapture(whenScreenIsConfirm: Bool) -> Bool {
        !whenScreenIsConfirm
    }
}

/// Temp WAV helpers — mode 0600; callers must cleanup after success/error/cancel.
public enum SpeechTempAudioStore: Sendable {
    public static func makeTempWAVURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("QuietCalendarSpeech", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("capture-\(UUID().uuidString).wav")
    }

    public static func applyPrivatePermissions(at url: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func cleanup(_ url: URL?, fileManager: FileManager = .default) {
        guard let url else { return }
        try? fileManager.removeItem(at: url)
    }
}
