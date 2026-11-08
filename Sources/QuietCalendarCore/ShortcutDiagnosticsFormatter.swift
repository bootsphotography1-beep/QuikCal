import Foundation

// MARK: - Copy shortcut diagnostics (0.3.13)
//
// A compact, honest per-process diagnostic the owner can copy and paste when
// the shortcut/practice page misbehaves — decisively sorting stale-TCC or
// wrong-copy problems (e.g. the 2026-11-07 evidence: System Settings toggle
// ON while the app still read "Not yet", and the onboarding one-time state
// carried across a fresh install).
//
// Facts only, per the owner's rules: app identity, code signature status,
// Accessibility trust AS FELT BY THE RUNNING PROCESS (never inferred from
// event delivery), listener install state, persisted INTENT, the SELECTED
// shortcut NAME (not key text), and press/release COUNTS (numbers only —
// no key content is ever recorded).

public struct ShortcutDiagnosticsFacts: Sendable, Equatable {
    public var appVersion: String
    public var bundlePath: String
    public var bundleID: String
    /// Self-describing signature summary: e.g. "ad-hoc valid" / "ad-hoc INVALID"
    /// — validity of the code object itself, read from the running process.
    public var codeSignature: String
    /// `AXIsProcessTrusted()` as the running process sees it right now.
    public var accessibilityTrustedNow: Bool
    /// Optional `CGPreflightListenEventAccess()` result (nil = not checked).
    public var inputMonitoringPreflight: Bool?
    /// At least one listener path (NSEvent monitors or the CGEventTap) is
    /// actually installed right now (observed, not intent).
    public var listenerInstalled: Bool
    /// The listen-only CGEventTap specifically — the path that captures
    /// Fn/Globe globally (2026-11-07). Observed install state, never faked.
    public var eventTapInstalled: Bool = false
    /// Persisted user intent: hold-to-talk enable flag (nil = never set).
    public var enabledIntent: Bool?
    /// Persisted monitoring state flag (restore intent).
    public var monitoringIntentPersisted: Bool
    public var selectedShortcut: String
    /// Actual detected hold cycles since launch (numbers only).
    public var holdCount: Int
    /// Actual detected release cycles since launch (numbers only).
    public var releaseCount: Int
    public var practiceReleaseCount: Int
    /// Timestamp of the last detected hold begin (nil = none this launch).
    public var lastHoldAt: Date?
    /// Timestamp of the last detected hold end (nil = none this launch).
    public var lastReleaseAt: Date?
    public var macOSVersion: String

    public init(
        appVersion: String,
        bundlePath: String,
        bundleID: String,
        codeSignature: String,
        accessibilityTrustedNow: Bool,
        inputMonitoringPreflight: Bool? = nil,
        listenerInstalled: Bool,
        eventTapInstalled: Bool = false,
        enabledIntent: Bool? = nil,
        monitoringIntentPersisted: Bool = false,
        selectedShortcut: String,
        holdCount: Int,
        releaseCount: Int,
        practiceReleaseCount: Int = 0,
        lastHoldAt: Date? = nil,
        lastReleaseAt: Date? = nil,
        macOSVersion: String
    ) {
        self.appVersion = appVersion
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.codeSignature = codeSignature
        self.accessibilityTrustedNow = accessibilityTrustedNow
        self.inputMonitoringPreflight = inputMonitoringPreflight
        self.listenerInstalled = listenerInstalled
        self.eventTapInstalled = eventTapInstalled
        self.enabledIntent = enabledIntent
        self.monitoringIntentPersisted = monitoringIntentPersisted
        self.selectedShortcut = selectedShortcut
        self.holdCount = holdCount
        self.releaseCount = releaseCount
        self.practiceReleaseCount = practiceReleaseCount
        self.lastHoldAt = lastHoldAt
        self.lastReleaseAt = lastReleaseAt
        self.macOSVersion = macOSVersion
    }
}

public enum ShortcutDiagnosticsFormatter: Sendable {
    public static let title = "QuikCal shortcut diagnostics"

    /// Builds the copyable text. Every field above is a non-secret fact, and
    /// the shortcut appears only as its NAME — no key content, no values.
    public static func render(_ facts: ShortcutDiagnosticsFacts) -> String {
        var lines: [String] = []
        lines.append("QuikCal shortcut diagnostics")
        lines.append("app_version: \(facts.appVersion)")
        lines.append("macOS: \(facts.macOSVersion)")
        lines.append("running_path: \(facts.bundlePath)")
        lines.append("bundle_id: \(facts.bundleID)")
        lines.append("signature: \(facts.codeSignature)")
        lines.append("ax_trust_process: \(facts.accessibilityTrustedNow ? "yes" : "no")")
        if let inputMonitoring = facts.inputMonitoringPreflight {
            lines.append("input_monitoring_preflight: \(inputMonitoring ? "yes" : "no")")
        }
        lines.append("listener_installed: \(facts.listenerInstalled ? "yes" : "no")")
        lines.append("fn_event_tap_installed: \(facts.eventTapInstalled ? "yes" : "no")")
        lines.append("enabled_intent: \(facts.enabledIntent.map { $0 ? "on" : "off" } ?? "unset")")
        lines.append("monitor_intent_saved: \(facts.monitoringIntentPersisted ? "yes" : "no")")
        lines.append("selected_shortcut: \(facts.selectedShortcut)")
        lines.append("press_count: \(facts.holdCount)")
        lines.append("release_count: \(facts.releaseCount)")
        lines.append("practice_release_count: \(facts.practiceReleaseCount)")
        lines.append("last_press_time: \(facts.lastHoldAt.map { Self.timestampString($0) } ?? "none")")
        lines.append("last_release_time: \(facts.lastReleaseAt.map { Self.timestampString($0) } ?? "none")")
        return lines.joined(separator: "\n")
    }

    /// Stable UTC timestamp for the copyable diagnostics (numbers and
    /// times only — never key content). Value-type format style: no
    /// non-Sendable global (Swift 6).
    private static func timestampString(_ date: Date) -> String {
        date.formatted(
            .iso8601
                .year().month().day()
                .dateSeparator(.dash)
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .colon)
        )
    }
}
