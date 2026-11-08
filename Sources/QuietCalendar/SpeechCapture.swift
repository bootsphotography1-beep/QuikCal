import Foundation
import AVFoundation
import QuietCalendarCore

/// Microphone capture → 16 kHz mono WAV → bundled local Parakeet helper.
///
/// * Microphone permission is requested only on user intent (mic / hold-to-talk) — never at launch.
/// * No Apple Speech, no cloud fallback.
/// * Temp WAVs use mode 0600 and are deleted after success / error / cancel.
/// * Async helper inference; cancel/timeout terminates **only** this session’s helper process.
/// * Generation / session guards drop late transcripts.
@MainActor
final class SpeechCapture: ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var message: String?
    @Published private(set) var transcript: String = ""
    @Published private(set) var modelReadiness: ParakeetModelReadiness = .missing
    /// P2 live preview: genuine rolling captured-so-far transcript
    /// (NON-AUTHORITATIVE — never feeds the parser; only the final
    /// validated transcript at release does). Empty when no preview exists.
    @Published private(set) var partialTranscript: String = ""
    /// P2 live feedback: real microphone RMS amplitude (0…1), published at
    /// ~20 Hz while recording. Derived from the actual tap buffers — no
    /// fake animation.
    @Published private(set) var amplitude: Double = 0

    var onFinalTranscript: ((String) -> Void)?

    private let client: ParakeetTranscribeClient
    private let modelURLProvider: () -> URL
    private let helperURLProvider: () -> URL?
    private let timeoutSeconds: TimeInterval

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var pcmAccumulator = Data()
    private var pcmSink: ThreadSafePCMAccumulator?
    private var tempAudioURL: URL?
    private var generation = 0
    private var activeSessionID = 0
    private var inferenceTask: Task<Void, Never>?

    // MARK: P2 live-preview engine (bounded rolling captured-so-far snapshots)
    //
    // The pinned helper CLI loads a COMPLETE WAV from a file path (exact
    // frame count required), so a live stdin PCM feed is impossible with
    // the existing runtime. Instead, while recording, the captured-so-far
    // PCM is periodically transcribed through the EXISTING client — ONE
    // owned helper process in flight at a time, at a bounded interval
    // (never per 640 ms frame) — and the genuine result is shown as a
    // non-authoritative preview. The authoritative transcript is still
    // the full one-shot transcription at release (unchanged path).
    private var previewState = LivePreviewState()
    private var previewLoopTask: Task<Void, Never>?
    private var snapshotSessionID = 0
    private var snapshotInFlight = false
    private var lastSnapshotAtCapturedSeconds: Double?
    private var currentHelperURL: URL?
    private let amplitudeBox = ThreadSafeAmplitudeBox()

    init(
        client: ParakeetTranscribeClient = ProcessParakeetTranscribeClient(),
        modelURLProvider: @escaping () -> URL = {
            AppPreferencesStore().resolveParakeetModelURL()
        },
        helperURLProvider: @escaping () -> URL? = {
            ParakeetRuntimeLocator.helperURL()
        },
        timeoutSeconds: TimeInterval = 90
    ) {
        self.client = client
        self.modelURLProvider = modelURLProvider
        self.helperURLProvider = helperURLProvider
        self.timeoutSeconds = timeoutSeconds
        refreshModelReadiness()
    }

    func refreshModelReadiness() {
        let validation = ParakeetModelValidator.validate(
            fileURL: modelURLProvider(),
            requireChecksum: false
        )
        if helperURLProvider() == nil {
            modelReadiness = .helperMissing
        } else {
            modelReadiness = validation.readiness
        }
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .requesting, .recording:
            stop()
        case .finishing:
            break
        }
    }

    func start() {
        guard state == .idle else { return }
        state = .requesting
        message = nil
        transcript = ""
        generation += 1
        let token = generation
        refreshModelReadiness()
        // P2: fresh capture session — no stale preview may leak in.
        previewState.reset()
        partialTranscript = ""
        amplitude = 0
        amplitudeBox.store(0)
        snapshotInFlight = false
        lastSnapshotAtCapturedSeconds = nil

        Task { [weak self] in
            guard let self else { return }
            let microphone = await Self.requestMicrophoneAccess()
            guard self.generation == token, self.state == .requesting else { return }
            guard microphone else {
                self.fail("Microphone permission was not granted. You can still type.", token: token)
                return
            }
            self.beginCapture(token: token)
        }
    }

    func stop() {
        switch state {
        case .requesting:
            // P0 (preflight P2 race): a trusted release during the async
            // permission/start window captured NOTHING. Resolve honestly —
            // set the visible message BEFORE cancelling so the pill's
            // speech.$message observation always fires; never a silent
            // return to idle (the stuck-"Working…" defect).
            message = HoldOutcomeCopy.nothingCaughtCopy
            cancel()
        case .recording:
            state = .finishing
            stopLivePreview()
            finishCaptureAndTranscribe(token: generation)
        case .idle, .finishing:
            break
        }
    }

    func cancel() {
        generation += 1
        let session = activeSessionID
        activeSessionID = 0
        stopLivePreview()
        inferenceTask?.cancel()
        inferenceTask = nil
        client.cancel(sessionID: session)
        teardownEngine()
        SpeechTempAudioStore.cleanup(tempAudioURL)
        tempAudioURL = nil
        pcmSink = nil
        pcmAccumulator.removeAll(keepingCapacity: false)
        state = .idle
    }

    // MARK: - Live preview (P2)

    /// Tears the preview engine down: cancel the loop, cancel the ONE
    /// in-flight snapshot helper (our own child only), freeze the preview
    /// state so a late snapshot can never overwrite anything.
    private func stopLivePreview() {
        previewLoopTask?.cancel()
        previewLoopTask = nil
        if snapshotInFlight {
            client.cancel(sessionID: snapshotSessionID)
            snapshotInFlight = false
        }
        previewState.markFinalized()
    }

    /// ~20 Hz loop while recording: publishes the real tap RMS amplitude
    /// and starts bounded rolling snapshots when the policy says so.
    private func startLivePreviewLoop(token: Int) {
        previewLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                guard self.generation == token, self.state == .recording else { return }
                self.publishAmplitude()
                self.startSnapshotIfDue(token: token)
            }
        }
    }

    private func publishAmplitude() {
        let value = amplitudeBox.load()
        if abs(value - amplitude) > 0.01 {
            amplitude = value
        }
    }

    private var capturedSeconds: Double {
        Double(pcmSink?.totalByteCount ?? 0) / 32_000.0  // 16 kHz × Int16 mono
    }

    private func startSnapshotIfDue(token: Int) {
        guard LiveSnapshotPolicy.shouldStartSnapshot(
            capturedSeconds: capturedSeconds,
            lastSnapshotAtCapturedSeconds: lastSnapshotAtCapturedSeconds,
            snapshotInFlight: snapshotInFlight
        ) else { return }
        guard let sink = pcmSink, let helper = currentHelperURL else { return }
        let pcm = sink.copyData()
        guard !pcm.isEmpty else { return }
        snapshotInFlight = true
        lastSnapshotAtCapturedSeconds = capturedSeconds
        let revision = previewState.beginRevision()
        // Snapshot sessions live in a disjoint ID space from the final
        // transcription session (= generation token).
        let sessionID = token &+ 1_000_000
        snapshotSessionID = sessionID
        let client = self.client
        let modelURL = modelURLProvider()
        let timeout = timeoutSeconds
        Task { [weak self] in
            do {
                let url = try SpeechTempAudioStore.makeTempWAVURL()
                defer { SpeechTempAudioStore.cleanup(url) }
                try Self.writeWAV(pcmInt16Mono16k: pcm, to: url)
                let request = ParakeetTranscribeRequest(
                    audioURL: url,
                    modelURL: modelURL,
                    helperURL: helper,
                    timeoutSeconds: timeout,
                    sessionID: sessionID
                )
                let result = try await client.transcribe(request)
                await MainActor.run { [weak self] in
                    self?.applySnapshotResult(result, revision: revision, token: token, sessionID: sessionID)
                }
            } catch {
                // Preview-only failure: fall back silently to the honest
                // amplitude + final-transcript path (never fake words).
                await MainActor.run { [weak self] in
                    self?.endSnapshot(token: token, sessionID: sessionID)
                }
            }
        }
    }

    private func applySnapshotResult(
        _ result: ParakeetTranscribeResult,
        revision: Int,
        token: Int,
        sessionID: Int
    ) {
        defer { endSnapshot(token: token, sessionID: sessionID) }
        // Generation guard: a new session's snapshot can never land here.
        guard generation == token, state == .recording else { return }
        guard result.sessionID == sessionID else { return }
        // Latest-wins revision guard: an older snapshot finishing late is
        // dropped; the preview NEVER feeds the parser.
        if previewState.apply(text: result.transcript, revision: revision) {
            partialTranscript = previewState.text
        }
    }

    private func endSnapshot(token: Int, sessionID: Int) {
        guard generation == token, snapshotSessionID == sessionID else { return }
        snapshotInFlight = false
    }

    // MARK: - Capture

    private func beginCapture(token: Int) {
        guard generation == token else { return }
        guard let helper = helperURLProvider() else {
            fail(ParakeetTranscribeError.helperMissing("bundle").userFacingMessage, token: token)
            return
        }
        let modelURL = modelURLProvider()
        let validation = ParakeetModelValidator.validate(fileURL: modelURL, requireChecksum: false)
        guard validation.readiness == .ready else {
            fail(validation.readiness.userFacingStatus, token: token)
            return
        }

        do {
            let url = try SpeechTempAudioStore.makeTempWAVURL()
            tempAudioURL = url
            pcmAccumulator.removeAll(keepingCapacity: true)
            currentHelperURL = helper

            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                fail("No usable microphone input was found. Type instead.", token: token)
                return
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ) else {
                fail("Could not create 16 kHz mono audio format.", token: token)
                return
            }
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            self.converter = converter
            let sink = ThreadSafePCMAccumulator()
            pcmSink = sink
            let amplitudeBox = self.amplitudeBox
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                Self.convert(buffer: buffer, converter: converter, into: sink, amplitudeBox: amplitudeBox)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            state = .recording
            // P2: live amplitude + bounded rolling snapshots while recording.
            startLivePreviewLoop(token: token)
        } catch {
            fail("Couldn't start the microphone: \(error.localizedDescription)", token: token)
        }
    }

    private func finishCaptureAndTranscribe(token: Int) {
        guard generation == token else { return }
        teardownEngine()

        let pcm = pcmSink?.takeData() ?? Data()
        pcmSink = nil
        pcmAccumulator.removeAll(keepingCapacity: false)
        guard pcm.count > 0, let audioURL = tempAudioURL else {
            SpeechTempAudioStore.cleanup(tempAudioURL)
            tempAudioURL = nil
            fail("Didn't catch that — try again or type.", token: token)
            return
        }

        do {
            try Self.writeWAV(pcmInt16Mono16k: pcm, to: audioURL)
            SpeechTempAudioStore.applyPrivatePermissions(at: audioURL)
        } catch {
            SpeechTempAudioStore.cleanup(audioURL)
            tempAudioURL = nil
            fail("Could not write capture audio.", token: token)
            return
        }

        guard let helper = helperURLProvider() else {
            SpeechTempAudioStore.cleanup(audioURL)
            tempAudioURL = nil
            fail(ParakeetTranscribeError.helperMissing("bundle").userFacingMessage, token: token)
            return
        }

        activeSessionID = token
        let request = ParakeetTranscribeRequest(
            audioURL: audioURL,
            modelURL: modelURLProvider(),
            helperURL: helper,
            timeoutSeconds: timeoutSeconds,
            sessionID: token
        )
        let client = self.client

        inferenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.transcribe(request)
                await MainActor.run {
                    self.complete(result: result, token: token, audioURL: audioURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.failAfterInference(
                        ParakeetTranscribeError.cancelled.userFacingMessage,
                        token: token,
                        audioURL: audioURL
                    )
                }
            } catch let error as ParakeetTranscribeError {
                await MainActor.run {
                    self.failAfterInference(error.userFacingMessage, token: token, audioURL: audioURL)
                }
            } catch {
                await MainActor.run {
                    self.failAfterInference(
                        "Local Parakeet failed. You can still type.",
                        token: token,
                        audioURL: audioURL
                    )
                }
            }
        }
    }

    private func complete(result: ParakeetTranscribeResult, token: Int, audioURL: URL) {
        SpeechTempAudioStore.cleanup(audioURL)
        if tempAudioURL == audioURL { tempAudioURL = nil }
        guard generation == token else { return }
        guard result.sessionID == token else { return }
        generation += 1
        activeSessionID = 0
        inferenceTask = nil
        state = .idle
        let trimmed = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            message = ParakeetTranscribeError.emptyTranscript.userFacingMessage
        } else {
            transcript = trimmed
            message = nil
            onFinalTranscript?(trimmed)
        }
    }

    private func failAfterInference(_ text: String, token: Int, audioURL: URL) {
        SpeechTempAudioStore.cleanup(audioURL)
        if tempAudioURL == audioURL { tempAudioURL = nil }
        fail(text, token: token)
    }

    private func fail(_ text: String, token: Int) {
        guard generation == token else { return }
        generation += 1
        activeSessionID = 0
        inferenceTask?.cancel()
        inferenceTask = nil
        stopLivePreview()
        teardownEngine()
        SpeechTempAudioStore.cleanup(tempAudioURL)
        tempAudioURL = nil
        pcmSink = nil
        pcmAccumulator.removeAll(keepingCapacity: false)
        state = .idle
        message = text
    }

    private func teardownEngine() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        converter = nil
    }

    // MARK: - Permissions

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Audio conversion / WAV

    private static func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        into sink: ThreadSafePCMAccumulator,
        amplitudeBox: ThreadSafeAmplitudeBox
    ) {
        guard let converter else { return }
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0,
              let channels = out.int16ChannelData else { return }
        let frameCount = Int(out.frameLength)
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: channels[0], count: byteCount)
        sink.append(data)
        // P2: real RMS amplitude from the ACTUAL converted samples (no
        // raw audio logging — only a scalar 0…1 is kept).
        amplitudeBox.store(Self.rms(data: data))
    }

    /// RMS of Int16 mono samples, normalized to 0…1 with a speech-friendly
    /// gain (quiet mics still read visibly on the waveform).
    static func rms(data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        let samples = data.withUnsafeBytes { raw -> [Int16] in
            let count = raw.count / 2
            return Array(raw.bindMemory(to: Int16.self).prefix(count))
        }
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768.0
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return min(1, rms * 3.5)
    }

    private static func writeWAV(pcmInt16Mono16k: Data, to url: URL) throws {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmInt16Mono16k.count)
        let riffSize = 36 + dataSize

        var header = Data()
        func appendASCII(_ s: String) { header.append(contentsOf: s.utf8) }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 2))
        }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 4))
        }

        appendASCII("RIFF")
        appendU32(riffSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(channels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendASCII("data")
        appendU32(dataSize)

        var file = header
        file.append(pcmInt16Mono16k)
        try file.write(to: url, options: .atomic)
        SpeechTempAudioStore.applyPrivatePermissions(at: url)
    }
}

/// Thread-safe PCM accumulator for the audio render/tap callback.
private final class ThreadSafePCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func takeData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let out = storage
        storage = Data()
        return out
    }

    /// P2 live preview: a copy WITHOUT draining (the accumulator keeps
    /// every sample for the authoritative final transcription at release).
    func copyData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var totalByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

/// Thread-safe scalar box for the latest tap RMS amplitude (audio thread
/// writes, main thread reads at ~20 Hz). No raw audio is ever retained.
final class ThreadSafeAmplitudeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func store(_ newValue: Double) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
