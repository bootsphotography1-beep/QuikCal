import Foundation
import Combine
import QuietCalendarCore

/// Shared ObservableObject for onboarding + Settings. QuikCal downloads only
/// the speech model; Apple Foundation Models are managed by macOS.
@MainActor
final class ParakeetModelDownloadController: ObservableObject {
    static let shared = ParakeetModelDownloadController()

    @Published private(set) var snapshot = ParakeetDownloadSnapshot()
    @Published private(set) var installedValidation = ParakeetModelValidation(readiness: .missing)

    private let speechEngine: ParakeetModelDownloadEngine
    private var pollTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    init() {
        self.speechEngine = ParakeetModelDownloadEngine()
    }

    init(speechEngine: ParakeetModelDownloadEngine) {
        self.speechEngine = speechEngine
    }

    var isTransferring: Bool {
        switch snapshot.phase {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    var isSpeechReady: Bool { snapshot.phase == .ready || installedValidation.readiness == .ready }

    func refresh() {
#if DEBUG
        if isQAFixtureActive { return }
#endif
        Task { await refreshAsync() }
    }

    func refreshAsync() async {
#if DEBUG
        if isQAFixtureActive { return }
#endif
        let speech = await speechEngine.refreshInstalledState(requireChecksum: false)
        installedValidation = speech.validation
        snapshot = speech.snapshot
    }

    /// Explicit speech-only install. Existing verified weights are skipped;
    /// cancellation preserves the partial file for a later resume.
    func startSpeechInstall(forceRestart: Bool = false) {
#if DEBUG
        if isQAFixtureActive {
            let state = qaFixtureState ?? .downloading
            if state == .missing || state == .error { applyQAFixture(.downloading) }
            return
        }
#endif
        guard !isTransferring else { return }
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }
            self.startPolling()
            self.snapshot = await self.speechEngine.startOrResume(forceRestart: forceRestart)
            await self.refreshAsync()
            self.stopPolling()
        }
    }

    func cancel() {
        Task { [weak self] in
            guard let self else { return }
            await self.speechEngine.cancel()
            transferTask?.cancel()
            self.snapshot = await self.speechEngine.currentSnapshot()
            await self.refreshAsync()
            self.stopPolling()
        }
    }

    func retry() { startSpeechInstall(forceRestart: false) }

    func restart() { startSpeechInstall(forceRestart: true) }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = await self.speechEngine.currentSnapshot()
                self.snapshot = current
                let active = current.phase == .downloading || current.phase == .verifying || current.phase == .installing
                if !active {
                    if self.transferTask == nil { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let latest = await self.speechEngine.currentSnapshot()
                    self.snapshot = latest
                    let stillActive = latest.phase == .downloading || latest.phase == .verifying || latest.phase == .installing
                    if !stillActive { break }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

#if DEBUG
    // Display-only QA fixtures: mock snapshots only, no network or disk writes.
    private(set) var qaFixtureState: QAModelsFixtureState?
    var isQAFixtureActive: Bool { qaFixtureState != nil }

    func applyQAFixture(_ state: QAModelsFixtureState) {
        qaFixtureState = state
        snapshot = QAModelsFixture.snapshots(for: state).speech
    }

    func clearQAFixture() {
        qaFixtureState = nil
    }
#endif
}
