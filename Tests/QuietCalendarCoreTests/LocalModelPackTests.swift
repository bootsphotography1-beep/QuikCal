import Testing
import Foundation
import CryptoKit
@testable import QuietCalendarCore

struct ParakeetModelCatalogTests {
    @Test func speechManifestIsTrustedDownloadable() {
        #expect(ParakeetModelCatalog.expectedBytes == ParakeetModelStore.expectedBytes)
        #expect(ParakeetModelCatalog.expectedSHA256 == ParakeetModelStore.expectedSHA256)
        #expect(ParakeetModelCatalog.pinnedDownloadURL.scheme == "https")
        #expect(ParakeetModelCatalog.isTrustedHost(ParakeetModelCatalog.pinnedDownloadURL.host))
    }

    @Test func trustedHostAllowlist() {
        #expect(ParakeetModelCatalog.isTrustedHost("huggingface.co"))
        #expect(ParakeetModelCatalog.isTrustedHost("cdn-lfs.huggingface.co"))
        #expect(!ParakeetModelCatalog.isTrustedHost("evil.example"))
        #expect(!ParakeetModelCatalog.isTrustedHost(nil))
    }
}

struct ParakeetDownloadEngineTests {
    private func tempModelsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tinyParakeetFixture(byteCount: Int = 256) -> (Data, String) {
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0, count: 16))
        data.append(Data("general.architecture".utf8))
        data.append(Data(repeating: 0, count: 8))
        data.append(Data("parakeet".utf8))
        data.append(Data(repeating: 0x41, count: max(0, byteCount - data.count)))
        if data.count > byteCount {
            data = data.prefix(byteCount)
        }
        while data.count < byteCount { data.append(0) }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (Data(data), hex)
    }

    @Test func mockDownloadSuccessInstallsAndSkipsRedownload() async throws {
        let dir = try tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (body, sha) = tinyParakeetFixture()
        let transport = MockParakeetDownloadTransport(behavior: .succeed(body, expectedLength: Int64(body.count)))
        let engine = ParakeetModelDownloadEngine(
            transport: transport,
            modelsDirectory: dir,
            fileName: "tiny-parakeet.gguf",
            expectedBytes: Int64(body.count),
            expectedSHA256: sha,
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        let first = await engine.startOrResume()
        #expect(first.phase == .ready)
        let dest = dir.appendingPathComponent("tiny-parakeet.gguf")
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let second = await engine.startOrResume()
        #expect(second.phase == .ready)
        #expect(second.message?.contains("already installed") == true)
    }

    @Test func mockDownloadChecksumFailureLeavesNoValidInstall() async throws {
        let dir = try tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (body, _) = tinyParakeetFixture()
        let transport = MockParakeetDownloadTransport(behavior: .succeed(body, expectedLength: Int64(body.count)))
        let engine = ParakeetModelDownloadEngine(
            transport: transport,
            modelsDirectory: dir,
            fileName: "tiny-bad.gguf",
            expectedBytes: Int64(body.count),
            expectedSHA256: String(repeating: "0", count: 64),
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        let result = await engine.startOrResume()
        #expect(result.phase == .failed)
        #expect(result.lastError?.contains("checksum") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tiny-bad.gguf").path))
    }

    @Test func mockDownloadCancelKeepsPartial() async throws {
        let dir = try tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = MockParakeetDownloadTransport(behavior: .hangUntilCancelled)
        let engine = ParakeetModelDownloadEngine(
            transport: transport,
            modelsDirectory: dir,
            fileName: "tiny-cancel.gguf",
            expectedBytes: 1000,
            expectedSHA256: String(repeating: "ab", count: 32),
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        let task = Task {
            await engine.startOrResume()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.cancel()
        _ = await task.value
        let snap = await engine.currentSnapshot()
        #expect(snap.phase == .cancelled)
    }

    @Test func mockTransportUntrustedRedirectFails() async throws {
        let dir = try tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = MockParakeetDownloadTransport(behavior: .untrustedHostRedirect)
        let engine = ParakeetModelDownloadEngine(
            transport: transport,
            modelsDirectory: dir,
            fileName: "tiny-redirect.gguf",
            expectedBytes: 10,
            expectedSHA256: String(repeating: "cd", count: 32),
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        let result = await engine.startOrResume()
        #expect(result.phase == .failed)
    }

    @Test func mockMidStreamFailureDoesNotReplaceExistingValid() async throws {
        let dir = try tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (body, sha) = tinyParakeetFixture(byteCount: 300)
        // Install valid first
        let okTransport = MockParakeetDownloadTransport(behavior: .succeed(body, expectedLength: Int64(body.count)))
        let engine = ParakeetModelDownloadEngine(
            transport: okTransport,
            modelsDirectory: dir,
            fileName: "tiny-keep.gguf",
            expectedBytes: Int64(body.count),
            expectedSHA256: sha,
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        _ = await engine.startOrResume()
        let dest = dir.appendingPathComponent("tiny-keep.gguf")
        let before = try Data(contentsOf: dest)

        // Force re-download with failing transport — should not wipe valid file on failure path
        // (engine skips when already ready unless forceRestart; forceRestart then fail)
        let failTransport = MockParakeetDownloadTransport(
            behavior: .failAfterBytes(40, body: body)
        )
        let engine2 = ParakeetModelDownloadEngine(
            transport: failTransport,
            modelsDirectory: dir,
            fileName: "tiny-keep.gguf",
            expectedBytes: Int64(body.count),
            expectedSHA256: sha,
            downloadURL: ParakeetModelCatalog.pinnedDownloadURL
        )
        // Without forceRestart, existing valid wins
        let skip = await engine2.startOrResume(forceRestart: false)
        #expect(skip.phase == .ready)
        #expect(try Data(contentsOf: dest) == before)

        let failed = await engine2.startOrResume(forceRestart: true)
        #expect(failed.phase == .failed)
        // Valid final should still exist (atomic install never completed)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == before)
    }
}

struct HoldToTalkGuideTests {
    @Test func guidePhasesNavigateAndSkip() {
        var guide = HoldToTalkGuideState(shortcut: .option)
        #expect(guide.phase == .pickShortcut)
        guide.goNext()
        #expect(guide.phase == .explainConflict)
        guide.goBack()
        #expect(guide.phase == .pickShortcut)
        guide.skipRemainder()
        #expect(guide.phase == .done)
        #expect(guide.accessibilityRecheck == .skipped)
    }

    @Test func permissionRecheckUnknownDeniedGranted() {
        var guide = HoldToTalkGuideState()
        #expect(guide.accessibilityRecheck == .unknown)
        #expect(HoldToTalkGuideCopy.recheckLabel(.unknown) == "Not checked yet")
        guide.applyAccessibilityTrusted(false)
        #expect(guide.accessibilityRecheck == .denied)
        #expect(HoldToTalkGuideCopy.recheckLabel(.denied) == "Not yet")
        guide.applyAccessibilityTrusted(true)
        #expect(guide.accessibilityRecheck == .granted)
        #expect(HoldToTalkGuideCopy.recheckLabel(.granted) == "Granted")
    }

    @Test func practiceConfirmPreservesNoWritePolicy() {
        var guide = HoldToTalkGuideState()
        guide.markPracticeHoldSeen()
        guide.confirmPractice()
        #expect(guide.practiceHoldSeen)
        #expect(guide.practiceConfirmed)
        #expect(!HoldToTalkGuideState.practiceMayWriteCalendar())
        #expect(HoldToTalkConfirmPolicy.shouldBeginCapture(whenScreenIsConfirm: true) == false)
    }

    @Test func requiredCapabilityGatesOnActualCapturePath() {
        // Fn/Globe is only seen globally by the listen-only CGEventTap →
        // Input Monitoring (listen-event access) is the required capability.
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .fn) == .inputMonitoring)
        // Other modifiers are captured by the global NSEvent monitor →
        // Accessibility is the required capability.
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .option) == .accessibility)
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .command) == .accessibility)
        #expect(HoldToTalkPermissionPolicy.requiredCapability(for: .control) == .accessibility)
    }

    @Test func mayStartMonitoringGatesOnRequiredCapabilityNeverArbitraryAX() {
        // Fn: Input Monitoring is required AND sufficient — AX alone
        // never starts Fn monitoring (creation ≠ delivery; the tap's
        // delivery is gated by listen-event access).
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .fn, accessibilityTrusted: false, inputMonitoringAllowed: true))
        #expect(!HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .fn, accessibilityTrusted: true, inputMonitoringAllowed: false))
        #expect(!HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .fn, accessibilityTrusted: false, inputMonitoringAllowed: false))
        // Other modifiers: EITHER capability captures (global NSEvent
        // monitor via AX, or the key tap via Input Monitoring).
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .option, accessibilityTrusted: true, inputMonitoringAllowed: false))
        #expect(HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .command, accessibilityTrusted: false, inputMonitoringAllowed: true))
        #expect(!HoldToTalkPermissionPolicy.mayStartMonitoring(shortcut: .control, accessibilityTrusted: false, inputMonitoringAllowed: false))
    }

    @Test func onboardingResumePreservesHoldGuideAndShortcutPrefs() {
        let suite = "qc.holdguide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.holdToTalkShortcut = .control
        var session = OnboardingSessionState(page: .voiceSetup)
        session.holdGuide.phase = .recheckPermission
        session.holdGuide.accessibilityRecheck = .denied
        session.holdGuide.practiceConfirmed = false
        session.practiceNote = "keep draft"
        prefs.saveOnboardingResume(session)

        let restored = prefs.makeOnboardingSession(forReplay: false)
        #expect(restored.page == .voiceSetup)
        #expect(restored.holdGuide.phase == .recheckPermission)
        #expect(restored.holdGuide.accessibilityRecheck == .denied)
        #expect(restored.practiceNote == "keep draft")
        #expect(prefs.holdToTalkShortcut == .control)

        // Settings reopen / replay must not wipe shortcut
        prefs.resetOnboardingCompletion()
        #expect(prefs.holdToTalkShortcut == .control)
    }

    @Test func fnConflictCopyDoesNotClaimSystemRemap() {
        let copy = HoldToTalkGuideCopy.conflictExplanation(for: .fn)
        #expect(copy.contains("does not change"))
        #expect(copy.lowercased().contains("globe") || copy.contains("Fn"))
    }
}
