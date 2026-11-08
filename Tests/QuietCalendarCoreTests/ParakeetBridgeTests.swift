import Testing
import Foundation
@testable import QuietCalendarCore

struct ParakeetBridgeTests {
    private var projectRoot: URL {
        // Tests/QuietCalendarCoreTests -> project root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    // MARK: Model missing / corrupt

    @Test func missingModelIsTypedMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-missing-\(UUID().uuidString).gguf")
        let result = ParakeetModelValidator.validate(fileURL: url, requireChecksum: false)
        #expect(result.readiness == .missing)
        #expect(!result.readiness.isUsable)
        #expect(result.readiness.userFacingStatus.contains("missing"))
    }

    @Test func corruptHeaderIsTypedCorrupt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-corrupt-\(UUID().uuidString).gguf")
        try Data("NOTGGUF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = ParakeetModelValidator.validate(fileURL: url, requireChecksum: false)
        #expect(result.readiness == .corrupt)
    }

    @Test func wrongArchitectureIsIncompatible() throws {
        // Minimal fake GGUF magic + architecture token that is not parakeet
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0, count: 32))
        data.append(Data("general.architecture".utf8))
        data.append(Data(repeating: 0, count: 8))
        data.append(Data("whisper".utf8))
        data.append(Data(repeating: 0, count: 64))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-arch-\(UUID().uuidString).gguf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = ParakeetModelValidator.validate(fileURL: url, requireChecksum: false)
        #expect(result.readiness == .incompatibleArchitecture)
        #expect(result.architecture == "whisper")
    }

    // MARK: Mock capture bridge / cancel

    @Test func mockClientReturnsTranscript() async throws {
        let client = MockParakeetTranscribeClient(behavior: .transcript("Meeting at noon for Sturm"))
        let req = ParakeetTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/fake.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/fake.gguf"),
            helperURL: URL(fileURLWithPath: "/tmp/helper"),
            sessionID: 7
        )
        let result = try await client.transcribe(req)
        #expect(result.transcript.contains("Meeting"))
        #expect(result.sessionID == 7)
        #expect(client.invocations.count == 1)
    }

    @Test func mockClientCancelWhileHanging() async throws {
        let client = MockParakeetTranscribeClient(behavior: .hangUntilCancelled)
        let req = ParakeetTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/fake.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/fake.gguf"),
            helperURL: URL(fileURLWithPath: "/tmp/helper"),
            timeoutSeconds: 5,
            sessionID: 99
        )
        let task = Task {
            try await client.transcribe(req)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        client.cancel(sessionID: 99)
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ParakeetTranscribeError {
            #expect(error == .cancelled)
        }
    }

    @Test func holdWhileConfirmDoesNotBeginCapture() {
        #expect(HoldToTalkConfirmPolicy.shouldBeginCapture(whenScreenIsConfirm: true) == false)
        #expect(HoldToTalkConfirmPolicy.shouldBeginCapture(whenScreenIsConfirm: false) == true)
    }

    // MARK: extractTranscript — real helper stdout + edge cases

    @Test func extractTranscriptStripsRealQuietStdoutTextPrefix() throws {
        let fixture = fixturesDir.appendingPathComponent("helper_stdout_synthetic_observed.txt")
        let stdout = try String(contentsOf: fixture, encoding: .utf8)
        let got = ProcessParakeetTranscribeClient.extractTranscript(from: stdout)
        #expect(got == "Meeting at noon for something in Sturm 320.")
        #expect(!got.lowercased().hasPrefix("text:"))
        #expect(!got.contains("realtime:"))
        #expect(!got.contains("audio:"))
    }

    @Test func extractTranscriptIgnoresDiagnosticsLegacyBareLine() {
        let stdout = """
        model: ok
        Meeting at noon for something in Sturm 320.
        realtime: 7x
        """
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: stdout)
            == "Meeting at noon for something in Sturm 320."
        )
    }

    @Test func extractTranscriptPreservesDictatedWordText() {
        // Helper key stripped once; dictated word "text" remains in value.
        let stdout = """
        run: ok
        text: text message tomorrow at noon
          realtime:   10x
        """
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: stdout)
            == "text message tomorrow at noon"
        )
    }

    @Test func extractTranscriptPreservesBareLineStartingWithTextWord() {
        // No colon → not helper metadata; keep literal dictation.
        let stdout = """
        run: ok
        text reminder for Sturm
        """
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: stdout)
            == "text reminder for Sturm"
        )
    }

    @Test func extractTranscriptMultilineValue() {
        let stdout = """
        run: ok
        text: Meeting at noon
        for something in Sturm 320.
          realtime:   12x
        """
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: stdout)
            == "Meeting at noon\nfor something in Sturm 320."
        )
    }

    @Test func extractTranscriptRejectsBlankEmptyAndDiagnosticsOnly() {
        #expect(ProcessParakeetTranscribeClient.extractTranscript(from: "") == "")
        #expect(ProcessParakeetTranscribeClient.extractTranscript(from: "   \n  ") == "")
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: """
            audio: /tmp/x.wav
            model: ok
            run: ok
              realtime: 1x
            """) == ""
        )
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: """
            run: ok
            text: (empty)
              realtime: 1x
            """) == ""
        )
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: """
            run: ok
            text:
              realtime: 1x
            """) == ""
        )
        #expect(
            ProcessParakeetTranscribeClient.extractTranscript(from: """
            run: ok
            text:   
              realtime: 1x
            """) == ""
        )
    }

    @Test func tempAudioPermissionsHelperCreatesPrivatePath() throws {
        let url = try SpeechTempAudioStore.makeTempWAVURL()
        try Data([0, 1, 2, 3]).write(to: url)
        SpeechTempAudioStore.applyPrivatePermissions(at: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        SpeechTempAudioStore.cleanup(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func legacyModelPreferenceIsNoLongerReadByProductionRouting() throws {
        let suite = "quietcalendar.parakeet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "quietCalendar.preferLocalModelAssist")
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let viewModel = try String(contentsOf: projectRoot.appendingPathComponent("Sources/QuietCalendar/ViewModel.swift"), encoding: .utf8)
        let appPreferences = try String(contentsOf: projectRoot.appendingPathComponent("Sources/QuietCalendarCore/AppPreferences.swift"), encoding: .utf8)
        #expect(!viewModel.contains("preferLocalModelAssist"))
        #expect(!viewModel.contains("preferLocalModel"))
        #expect(!appPreferences.contains("preferLocalModelAssist"))
        #expect(viewModel.contains("PhrasePipeline(calendar: calendar)"))
    }

    // MARK: Opt-in packaged synthetic (not soft-pass)

    /// Gated packaging acceptance. Default `swift test` **skips** this (not a pass).
    /// Run via `QC_RUN_PACKAGED_SYNTHETIC=1` or `scripts/accept_packaged_synthetic.sh`.
    /// Requires codesigned packaged helper + QuikCal Application Support weights only —
    /// no vendor CLI / Hex AS fallback.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["QC_RUN_PACKAGED_SYNTHETIC"] == "1",
            "Set QC_RUN_PACKAGED_SYNTHETIC=1 for packaged helper + QC-owned model acceptance (skipped otherwise; skip ≠ integration pass)"
        )
    )
    func packagedHelperSyntheticAcceptanceQCOwnedOnly() async throws {
        let helper = projectRoot
            .appendingPathComponent("build/QuikCal.app/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe")
        try #require(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "FAIL packaging: missing packaged helper at \(helper.path)"
        )

        // Require ad-hoc (or stronger) codesign — reject unsigned vendor copy mistaken for package.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        probe.arguments = ["--verify", "--verbose=2", helper.path]
        let err = Pipe()
        probe.standardError = err
        try probe.run()
        probe.waitUntilExit()
        try #require(
            probe.terminationStatus == 0,
            "FAIL packaging: packaged helper codesign verify failed"
        )

        let model = ParakeetModelStore.defaultModelURL()
        let hex = ParakeetModelStore.hexDevModelURL
        try #require(
            model.standardizedFileURL.path != hex.standardizedFileURL.path,
            "FAIL packaging: refusing Hex path as QC-owned model"
        )
        let readiness = ParakeetModelValidator.validate(fileURL: model, requireChecksum: false)
        try #require(
            readiness.readiness == .ready,
            "FAIL packaging: QC Application Support Parakeet model not ready at \(model.path)"
        )

        let fixture = projectRoot.appendingPathComponent(
            "local-models/stt-fixtures/SYNTHETIC_NOT_MIC_meeting_noon_sturm_16k_mono.wav"
        )
        try #require(
            FileManager.default.fileExists(atPath: fixture.path),
            "FAIL packaging: synthetic fixture missing at \(fixture.path)"
        )

        let client = ProcessParakeetTranscribeClient()
        let result = try await client.transcribe(
            ParakeetTranscribeRequest(
                audioURL: fixture,
                modelURL: model,
                helperURL: helper,
                timeoutSeconds: 120,
                sessionID: 20261105
            )
        )
        let transcript = result.transcript
        #expect(!transcript.isEmpty)
        #expect(!transcript.lowercased().hasPrefix("text:"))
        #expect(!transcript.contains("realtime:"))
        #expect(!transcript.contains("audio:"))
        let lower = transcript.lowercased()
        #expect(lower.contains("meeting") || lower.contains("noon") || lower.contains("sturm"))
    }
}
