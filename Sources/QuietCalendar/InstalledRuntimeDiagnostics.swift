import Foundation
import ApplicationServices
import CoreGraphics
import EventKit
import Security
import QuietCalendarCore

/// One-shot RELEASE-SAFE installed-runtime diagnostics (2026-11-07
/// integration). Invoked ONLY with an explicit flag:
///
///   QuikCal.app/Contents/MacOS/QuietCalendar --qc-runtime-diagnostics <path>
///
/// Runs in the ACTUAL installed signed app process (same binary, same
/// bundle, same TCC identity — a helper probe is NOT app trust proof)
/// and writes a plain-text dump of non-secret, READ-ONLY facts:
///
/// - own code signature (validity + team-signed vs ad-hoc, no chain),
/// - Accessibility trust NOW (`AXIsProcessTrusted` — no prompt),
/// - Input Monitoring preflight (`CGPreflightListenEventAccess` — no prompt),
/// - a REAL Fn event-tap install attempt (then uninstalled right after),
/// - EventKit authorization status + default-calendar availability
///   (no `request*` call — NOTHING prompts, no events are created),
/// - the PUBLIC Desktop OAuth client ID presence from Info.plist,
/// - the Google client-secret PRESENCE (Keychain existence query only —
///   the VALUE is never read, never logged; no bypass, no autoAllow),
/// - persisted hold-to-talk/onboarding intents from the REAL defaults
///   (read-only).
///
/// No prefs are written, no TCC grants are requested or bypassed, no UI is
/// shown; the process exits before the app starts (`main.swift`).
enum InstalledRuntimeDiagnostics {
    /// Collects the dump as "key: value" lines. Every line is a non-secret
    /// fact; unknown/unavailable facts are recorded honestly, never faked.
    /// MainActor: the event-tap probe is main-thread-only (same contract
    /// as the monitor), and `main.swift` invokes this on the main thread
    /// before the app starts.
    @MainActor
    static func collect() -> String {
        var lines: [String] = []
        lines.append("QuikCal installed-runtime diagnostics (read-only, no prompts)")
        lines.append("app_version: \(appVersion)")
        lines.append("bundle_id: \(bundleID)")
        lines.append("bundle_path: \(Bundle.main.bundlePath)")
        lines.append("executable_path: \(CommandLine.arguments.first ?? "unknown")")
        lines.append("code_signature: \(describeOwnSignature())")
        lines.append("macos_version: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Accessibility + input monitoring (real per-process probes, no prompts).
        lines.append("ax_trusted_now: \(AXIsProcessTrusted() ? "yes" : "no")")
        lines.append("input_monitoring_preflight: \(CGPreflightListenEventAccess() ? "yes" : "no")")

        // REAL Fn event-tap install attempt in THIS process (the same
        // listen-only tap hold-to-talk uses), uninstalled right after.
        let tap = HoldToTalkEventTap()
        let installed = tap.install(handler: { _ in })
        lines.append("fn_event_tap_install_attempt: \(installed ? "yes" : "no")")
        tap.uninstall()
        lines.append("fn_event_tap_uninstalled_after: \(!tap.isInstalled ? "yes" : "no")")

        // EventKit: authorization + default-calendar availability only.
        // No request* call — nothing prompts; no events are read or created.
        let store = EKEventStore()
        lines.append("eventkit_authorization_status: \(describeEKStatus(EKEventStore.authorizationStatus(for: .event)))")
        if let defaultCalendar = store.defaultCalendarForNewEvents {
            lines.append("eventkit_default_calendar_available: yes")
            lines.append("eventkit_default_calendar_writable: \(defaultCalendar.allowsContentModifications ? "yes" : "no")")
        } else {
            lines.append("eventkit_default_calendar_available: no")
            lines.append("eventkit_default_calendar_writable: no")
        }

        // Public Desktop OAuth client ID presence (public by design).
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleDesktopOAuthClientID") as? String
        lines.append("google_client_id_configured: \(!(clientID?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? "yes" : "no")")

        // Google client-secret PRESENCE only: a Keychain EXISTENCE query
        // (kSecReturnData false). The secret VALUE is never read, never
        // logged; no prompt is triggered, nothing is bypassed or auto-allowed.
        lines.append("google_client_secret_present: \(clientSecretPresent() ? "yes" : "no")")

        // Persisted intents from the REAL defaults domain (read-only).
        let prefs = AppPreferencesStore()
        lines.append("onboarding_completed: \(prefs.onboardingCompleted ? "yes" : "no")")
        switch prefs.holdToTalkEnabledExplicit {
        case .some(true): lines.append("hold_totalk_enabled_intent: yes")
        case .some(false): lines.append("hold_totalk_enabled_intent: no")
        case .none: lines.append("hold_totalk_enabled_intent: unset")
        }
        lines.append("hold_totalk_monitoring_intent: \(prefs.holdToTalkMonitoringEnabled ? "yes" : "no")")
        lines.append("calendar_destination: \(prefs.calendarDestinationKind.rawValue)")
        lines.append("selected_calendar_id_present: \(prefs.selectedCalendarID == nil ? "no" : "yes")")

        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the dump to `path`; returns the collected text. Errors are
    /// reported honestly by throwing (the caller records them).
    @MainActor
    static func write(to path: String) throws {
        try collect().write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private collectors

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    private static var bundleID: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String) ?? "unknown"
    }

    /// Own running code signature: validity plus ad-hoc vs team-signed.
    /// Never records the certificate chain.
    private static func describeOwnSignature() -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "unavailable (SecCodeCopySelf error)"
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return "unavailable (SecCodeCopyStaticCode error)"
        }
        let valid = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return (valid ? "valid" : "INVALID") + " (signing info unavailable)"
        }
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let shape = (teamID?.isEmpty ?? true) ? "ad-hoc" : "team-signed"
        let id = (dict[kSecCodeInfoIdentifier as String] as? String).map { " id=\($0)" } ?? ""
        return "\(valid ? "valid" : "INVALID") \(shape)\(id)"
    }

    private static func describeEKStatus(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .writeOnly: return "writeOnly"
        case .fullAccess: return "fullAccess"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Keychain EXISTENCE query for the Google client secret — presence
    /// boolean only, the value is never returned or logged.
    private static func clientSecretPresent() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainGoogleClientSecretStore.service,
            kSecAttrAccount as String: KeychainGoogleClientSecretStore.account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
