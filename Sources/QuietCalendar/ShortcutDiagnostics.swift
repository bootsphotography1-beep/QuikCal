import Foundation
import Security
import AppKit
import QuietCalendarCore

/// Gathers the per-process facts for the compact "Copy shortcut diagnostics"
/// button (0.3.13). Strictly read-only: no TCC access, no tokens/credentials,
/// no toggling, no prompts. Fields are non-secret facts only; the selected
/// shortcut appears as its NAME and hold/release history appears as NUMBERS
/// — no key content is ever recorded or copied.
enum ShortcutDiagnosticCollector {
    @MainActor
    static func facts(
        monitor: HoldToTalkMonitor,
        prefs: AppPreferencesStore
    ) -> ShortcutDiagnosticsFacts {
        // Code signature status of the RUNNING app — honest per-process
        // evidence for stale re-signed/moved-copy diagnosis (no declaration,
        // no entitlement handling: validity + the ad-hoc/TeamIdentifier fact).
        let signature = describeOwnSignature()
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
        let process = ProcessInfo.processInfo
        return ShortcutDiagnosticsFacts(
            appVersion: version,
            bundlePath: Bundle.main.bundlePath,
            bundleID: (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String) ?? "unknown",
            codeSignature: signature,
            accessibilityTrustedNow: monitor.accessibilityTrusted,
            inputMonitoringPreflight: monitor.inputMonitoringAllowed,
            listenerInstalled: monitor.monitorsInstalled,
            eventTapInstalled: monitor.eventTapInstalled,
            enabledIntent: prefs.holdToTalkEnabledExplicit,
            monitoringIntentPersisted: prefs.holdToTalkMonitoringEnabled,
            selectedShortcut: monitor.machine.shortcut.displayName,
            holdCount: monitor.holdCycleCount,
            releaseCount: monitor.releaseCycleCount,
            practiceReleaseCount: monitor.practiceReleaseCount,
            lastHoldAt: monitor.lastHoldAt,
            lastReleaseAt: monitor.lastReleaseAt,
            macOSVersion: "macOS \(process.operatingSystemVersionString)"
        )
    }

    /// Describes the OWN running code signature: validity plus ad-hoc vs
    /// team-signed. Never logs or copies the signing certificate chain.
    private static func describeOwnSignature() -> String {
        guard let staticCode = selfStaticCode() else {
            return "unavailable (static code error)"
        }
        let valid = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess
        var validity = valid ? "valid" : "INVALID"
        if validity.isEmpty { validity = "unknown" }
        let info: [String: Any]? = signingInformation(staticCode)
        let identifier = info?[kSecCodeInfoIdentifier as String] as? String
        let teamID = info?[kSecCodeInfoTeamIdentifier as String] as? String
        let shape: String
        if let teamID, !teamID.isEmpty {
            shape = "team-signed"
        } else {
            shape = "ad-hoc"
        }
        let idPart = identifier.map { " id=\($0)" } ?? ""
        return "\(validity) \(shape)\(idPart)"
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        return staticCode
    }

    private static func signingInformation(_ staticCode: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess, let info, let dict = info as? [String: Any] else {
            return nil
        }
        return dict
    }
}
