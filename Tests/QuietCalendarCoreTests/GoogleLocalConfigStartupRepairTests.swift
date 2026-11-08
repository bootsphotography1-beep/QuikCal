import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 — local Google Desktop client-JSON import into the dedicated
/// Keychain item, launch readiness repair, practice-detection honesty, and
/// the corrected per-request diagnostics field list.
///
/// Bounds pinned by the 2026-11-07 live evidence (owner diagnostic, names
/// only): HTTP 400 `invalid_request` + `missing_parameter: client_secret` +
/// `client_secret_sent: no` from a sign-in WITHOUT a secret; System Settings
/// toggle ON while the process read "Not yet"; practice page showing
/// "Released — nothing saved." straight from the Try-it press.
@Suite("Google Local Config Startup Repair 0313")
struct GoogleLocalConfigStartupRepairTests {

    private let boundClientID = "823797884893-vajrcj282mkcgc57aduiovqtd3pnq35b.apps.googleusercontent.com"

    private func desktopJSON(
        clientID: String = "823797884893-vajrcj282mkcgc57aduiovqtd3pnq35b.apps.googleusercontent.com",
        clientSecret: String = "GOCSPX-test-secret-value",
        extraClientKeys: [String: Any] = [:]
    ) -> Data {
        var client: [String: Any] = [
            "project_id": "quiet-calendar-1234",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uris": ["http://localhost"],
            "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs"
        ]
        for (key, value) in extraClientKeys { client[key] = value }
        return try! JSONSerialization.data(withJSONObject: ["installed": client])
    }

    // MARK: Strict JSON validation

    @Test func acceptsDesktopInstalledObject() throws {
        let imported = try GoogleClientSecretJSONImporter.validate(
            desktopJSON(), boundClientID: boundClientID)
        #expect(imported.clientID == boundClientID)
        #expect(imported.clientSecret == "GOCSPX-test-secret-value")
    }

    @Test func rejectsWebClientJSON() {
        let web = try! JSONSerialization.data(withJSONObject: [
            "web": [
                "client_id": boundClientID,
                "client_secret": "GOCSPX-test-secret-value"
            ] as [String: Any]
        ])
        #expect(throws: GoogleClientSecretImportError.incompatibleWebClient) {
            try GoogleClientSecretJSONImporter.validate(web, boundClientID: boundClientID)
        }
    }

    @Test func rejectsUnknownRootKey() {
        let unknown = Data(#"{"other":{"client_id":"x"}}"#.utf8)
        #expect(throws: GoogleClientSecretImportError.missingInstalledObject) {
            try GoogleClientSecretJSONImporter.validate(unknown, boundClientID: boundClientID)
        }
    }

    @Test func rejectsEmptyOversizedAndUnparseable() {
        #expect(throws: GoogleClientSecretImportError.emptyFile) {
            try GoogleClientSecretJSONImporter.validate(Data(), boundClientID: boundClientID)
        }
        let oversized = Data(repeating: 0x7B, count: GoogleClientSecretJSONImporter.maxFileBytes + 1)
        #expect(throws: GoogleClientSecretImportError.tooLarge(maxBytes: GoogleClientSecretJSONImporter.maxFileBytes)) {
            try GoogleClientSecretJSONImporter.validate(oversized, boundClientID: boundClientID)
        }
        #expect(throws: GoogleClientSecretImportError.unusableJSON) {
            try GoogleClientSecretJSONImporter.validate(Data("not json".utf8), boundClientID: boundClientID)
        }
    }

    @Test func rejectsMissingIDOrSecret() {
        // Serialize through JSON to build shapes missing one member.
        var installed = try! JSONSerialization.jsonObject(
            with: desktopJSON()) as! [String: [String: Any]]
        installed["installed"]!.removeValue(forKey: "client_id")
        let noID = try! JSONSerialization.data(withJSONObject: installed)
        #expect(throws: GoogleClientSecretImportError.missingClientID) {
            try GoogleClientSecretJSONImporter.validate(noID, boundClientID: boundClientID)
        }
        var secretless = try! JSONSerialization.jsonObject(
            with: desktopJSON()) as! [String: [String: Any]]
        secretless["installed"]!.removeValue(forKey: "client_secret")
        let noSecret = try! JSONSerialization.data(withJSONObject: secretless)
        #expect(throws: GoogleClientSecretImportError.missingClientSecret) {
            try GoogleClientSecretJSONImporter.validate(noSecret, boundClientID: boundClientID)
        }
    }

    @Test func rejectsEmptySecretAndOversizedSecret() {
        #expect(throws: GoogleClientSecretImportError.missingClientSecret) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(clientSecret: "   "), boundClientID: boundClientID)
        }
        #expect(throws: GoogleClientSecretImportError.secretTooLong) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(clientSecret: String(repeating: "x", count: 513)),
                boundClientID: boundClientID)
        }
    }

    @Test func rejectsMalformedClientIDShape() {
        #expect(throws: GoogleClientSecretImportError.missingClientID) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(clientID: "not-a-google-client-id"), boundClientID: boundClientID)
        }
        #expect(throws: GoogleClientSecretImportError.missingClientID) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(clientID: String(repeating: "a", count: 129) + ".apps.googleusercontent.com"),
                boundClientID: boundClientID)
        }
    }

    @Test func rejectsDifferentClientIDThanBoundConfig() {
        #expect(throws: GoogleClientSecretImportError.clientIDNotMatchingBoundConfig) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(clientID: "999-other.apps.googleusercontent.com"),
                boundClientID: boundClientID)
        }
    }

    @Test func redirectsMustBeStringArray() {
        #expect(throws: GoogleClientSecretImportError.missingInstalledObject) {
            try GoogleClientSecretJSONImporter.validate(
                desktopJSON(extraClientKeys: ["redirect_uris": ["nested": "dict"]]),
                boundClientID: boundClientID)
        }
    }

    // MARK: Validate-before-save ordering (atomic behavior)

    private final class RecordingStore: GoogleClientSecretPersisting, @unchecked Sendable {
        var operations: [String] = []
        var savedSecrets: [String] = []
        var savedSecret: String?
        func save(_ secret: String) throws {
            operations.append("save")
            savedSecrets.append(secret)
            savedSecret = secret
        }
        func load() throws -> String? {
            operations.append("load")
            return savedSecret
        }
        func delete() throws {
            operations.append("delete")
            savedSecret = nil
        }
    }

    @Test func importServiceValidatesFullyBeforeAnySave() throws {
        let store = RecordingStore()
        let service = GoogleClientSecretImportService(persisting: store)
        let imported = try service.importConfiguration(
            fileData: desktopJSON(), boundClientID: boundClientID)
        #expect(imported.clientSecret == "GOCSPX-test-secret-value")
        // Validation succeeded → exactly one save, no earlier mutations.
        #expect(store.operations == ["save"])
    }

    @Test func importServiceWritesNothingWhenValidationFails() {
        let store = RecordingStore()
        // Seed a PREVIOUS import — a failing import must preserve it.
        let previous = GoogleClientSecretImportService(persisting: store)
        try? previous.importConfiguration(
            fileData: desktopJSON(), boundClientID: boundClientID)
        precondition(store.savedSecret == "GOCSPX-test-secret-value")

        let service = GoogleClientSecretImportService(persisting: store)
        let mismatched = Data(#"{"installed":{"client_id":"555-other.apps.googleusercontent.com","client_secret":"GOCSPX-elsewhere"}}"#.utf8)
        #expect(throws: GoogleClientSecretImportError.clientIDNotMatchingBoundConfig) {
            try service.importConfiguration(fileData: mismatched, boundClientID: boundClientID)
        }
        // Nothing was written: old Keychain item untouched, no delete, no save.
        #expect(store.operations == ["save"])
        #expect(store.savedSecret == "GOCSPX-test-secret-value")
        #expect(!store.savedSecrets.contains("GOCSPX-elsewhere"))
    }

    // MARK: Secret resolution precedence

    @Test func envExplicitDevFallbackWins() {
        #expect(GoogleClientSecretResolutionPolicy.resolve(
            environmentSecret: "GOCSPX-env", storedSecret: "GOCSPX-stored") == "GOCSPX-env")
        #expect(GoogleClientSecretResolutionPolicy.resolve(
            environmentSecret: "   ", storedSecret: "GOCSPX-stored") == "GOCSPX-stored")
        #expect(GoogleClientSecretResolutionPolicy.resolve(
            environmentSecret: nil, storedSecret: nil) == nil)
        #expect(GoogleClientSecretResolutionPolicy.resolve(
            environmentSecret: nil, storedSecret: "GOCSPX-stored") == "GOCSPX-stored")
    }

    // MARK: Diagnostics — actual emitted field names

    @Test func diagnostics_requestFieldsExcludeClientSecretWhenNotSent() {
        let summary = GoogleOAuthDiagnostics.copyableSummary(
            status: 400,
            googleError: "invalid_request",
            missingParameter: "client_secret",
            usesClientSecret: false,
            appVersion: "0.3.13",
            bundlePath: "/Applications/QuikCal.app"
        )
        #expect(summary.contains("client_secret_sent: no"))
        #expect(summary.contains("missing_parameter: client_secret"))
        // The 2026-11-07 live diagnostic listed client_secret inside
        // request_fields while it was NOT sent — must never happen again.
        let fieldsLine = summary.split(separator: "\n")
            .first { $0.hasPrefix("request_fields:") } ?? ""
        #expect(!fieldsLine.contains("client_secret"))
        for name in ["code", "redirect_uri", "client_id", "code_verifier", "grant_type"] {
            #expect(fieldsLine.contains(name))
        }
    }

    @Test func diagnostics_requestFieldsIncludeClientSecretWhenSent() {
        let fields = GoogleOAuthDiagnostics.actualRequestFieldNames(usesClientSecret: true)
        #expect(fields == ["code", "redirect_uri", "client_id", "code_verifier", "grant_type", "client_secret"])
        let summary = GoogleOAuthDiagnostics.copyableSummary(
            status: 400,
            googleError: "invalid_request",
            missingParameter: nil,
            usesClientSecret: true,
            appVersion: "0.3.13",
            bundlePath: "/Applications/QuikCal.app"
        )
        #expect(summary.contains("client_secret_sent: yes"))
        let fieldsLine = summary.split(separator: "\n")
            .first { $0.hasPrefix("request_fields:") } ?? ""
        #expect(fieldsLine.contains("client_secret"))
    }

    @Test func missingSecretMessageNamesReachableSettingsAction() {
        let failure = GoogleEndpointFailureFactory.make(
            status: 400,
            googleError: "invalid_request",
            missingParameter: "client_secret"
        )
        #expect(failure.userFacingMessage.contains("Import Google configuration"))
        #expect(failure.userFacingMessage.contains("Settings"))
        #expect(failure.userFacingMessage.contains("missing parameter: client_secret"))
        // No values, no URLs — parameter NAMES only.
        #expect(!failure.userFacingMessage.contains("GOCSPX"))
        #expect(!failure.userFacingMessage.contains("://"))
    }

    // MARK: Launch readiness repair

    @Test func completedProfileWithBrokenRequiredCapabilityRepairs() {
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        ) == .repairHoldToTalkGuide)
    }

    @Test func optionalSkippedOrDisabledStaysSilent() {
        // Never enabled (nil = skipped/never asked) — silent.
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: nil,
            accessibilityTrustedNow: false
        ) == .none)
        // Explicitly disabled — silent, never re-nagged.
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: false
        ) == .none)
        // Enabled AND trusted — nothing to repair.
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: true
        ) == .none)
        // Incomplete profile stays owned by AppLaunchRouter.
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: false,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        ) == .none)
    }

    // MARK: Practice detection honesty

    @Test func detectedReleaseOnlyFromRealHoldTransition() {
        #expect(PracticeDetectionPolicy.isDetectedRelease(
            previousPhase: .holding, newPhase: .idle))
        #expect(PracticeDetectionPolicy.isDetectedRelease(
            previousPhase: .holding, newPhase: .releasing))
        // Button press (never holding) is never a release.
        #expect(!PracticeDetectionPolicy.isDetectedRelease(
            previousPhase: .idle, newPhase: .idle))
        #expect(!PracticeDetectionPolicy.isDetectedRelease(
            previousPhase: .releasing, newPhase: .idle))
    }

    @Test func practiceStatusIsHonestWhenDetectionInactive() {
        // Monitor not installed + Accessibility NOT trusted (the inline
        // permission row is on THIS page now): point at it, never say
        // "previous step", never imply "Waiting…" would work.
        let status = PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: false, listenerInstalled: false,
            accessibilityTrusted: false, shortcutName: "Fn")
        #expect(status == "Enable Accessibility above, then check again.")
        #expect(!status.contains("previous step"))
        #expect(!status.contains("Waiting"))
        #expect(!status.contains("Released"))

        // Trusted but the listener is not installed: do NOT re-ask for a
        // grant that already exists — hold-to-talk itself is not enabled.
        let trustedNoListener = PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: false, listenerInstalled: false,
            accessibilityTrusted: true, shortcutName: "Fn")
        #expect(trustedNoListener == "Enable hold-to-talk, then try again.")
        #expect(!trustedNoListener.contains("Accessibility"))
        #expect(!trustedNoListener.contains("Waiting"))

        // Installed, no detected release yet: waiting, honest.
        #expect(PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: false, listenerInstalled: true,
            accessibilityTrusted: true, shortcutName: "Fn") == "Waiting for a hold…")

        // Real detected release: released + nothing saved.
        #expect(PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: true, listenerInstalled: true,
            accessibilityTrusted: true, shortcutName: "Fn") == "Released — nothing saved.")

        // Mid-hold.
        #expect(PracticeDetectionPolicy.practiceStatusText(
            phase: .holding, releaseDetected: false, listenerInstalled: true,
            accessibilityTrusted: true, shortcutName: "Fn") == "Holding… release to preview.")
    }

    // MARK: Shortcut diagnostics output safety

    @Test func diagnosticsFormatCarriesNoKeyTextAndCountsAsNumbers() {
        let facts = ShortcutDiagnosticsFacts(
            appVersion: "0.3.13",
            bundlePath: "/Applications/QuikCal.app",
            bundleID: "com.quietcalendar.app",
            codeSignature: "valid ad-hoc id=com.quietcalendar.app",
            accessibilityTrustedNow: false,
            inputMonitoringPreflight: true,
            listenerInstalled: false,
            enabledIntent: true,
            monitoringIntentPersisted: true,
            selectedShortcut: "Fn",
            holdCount: 0,
            releaseCount: 0,
            practiceReleaseCount: 0,
            macOSVersion: "macOS 27.2"
        )
        let text = ShortcutDiagnosticsFormatter.render(facts)
        #expect(text.contains("app_version: 0.3.13"))
        #expect(text.contains("running_path: /Applications/QuikCal.app"))
        #expect(text.contains("signature: valid ad-hoc id=com.quietcalendar.app"))
        #expect(text.contains("ax_trust_process: no"))
        #expect(text.contains("listener_installed: no"))
        #expect(text.contains("enabled_intent: on"))
        #expect(text.contains("selected_shortcut: Fn"))
        #expect(text.contains("press_count: 0"))
        #expect(text.contains("release_count: 0"))
        #expect(text.contains("practice_release_count: 0"))
    }
}
