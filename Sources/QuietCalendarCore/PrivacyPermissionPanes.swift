import Foundation

// MARK: - Real capability model (2026-11-07 input/mic privacy repair)
//
// The Fn/Globe key is a system-consumed modifier: while QuikCal is not
// frontmost it is only seen by the LISTEN-ONLY CGEventTap, and macOS
// gates that tap's event DELIVERY behind Input Monitoring (listen-event
// access — `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`).
// Tap CREATION can succeed in an untrusted process (proven 2026-11-07,
// launch-context experiment B in QUIKCAL-LIVE-AX-MISMATCH-20261107.md),
// so creation is NEVER treated as delivery proof.
//
// Standard modifiers (Option/Command/Control) are delivered by the
// global NSEvent monitor, which macOS gates behind Accessibility; the
// listen-only tap (Input Monitoring) sees their flagsChanged too, so
// EITHER capability captures them.
//
// Microphone is its own AVCaptureDevice authorization, requested only
// on a user hold/capture action — never at launch, never from a
// permission page. Screen & System Audio Recording is NOT consumed by
// any QuikCal feature (voice capture is microphone-only) and is never
// requested or gated; its pane link exists for completeness only.

/// The macOS permission capability that actually gates a capture path.
public enum HoldToTalkCapability: String, Sendable, Equatable, CaseIterable {
    case accessibility
    case inputMonitoring

    public var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
}

/// Privacy & Security panes QuikCal can open on request — always from
/// an explicit button, never an automatic parade of panels at launch.
public enum PrivacyPaneKind: String, Sendable, Equatable, CaseIterable {
    case accessibility
    case inputMonitoring
    case microphone
    case screenRecording

    public var paneDisplayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .microphone: return "Microphone"
        // macOS 15+ row name; the same pane anchor covers the older
        // "Screen Recording" name (macOS 13–14).
        case .screenRecording: return "Screen & System Audio Recording"
        }
    }

    /// Preferred System Settings deep-link candidates (tried in order;
    /// failure → manual copy). Anchors are the pane anchors used by
    /// System Settings; the Screen pane keeps the `Privacy_ScreenCapture`
    /// anchor on macOS 15+ where the row is renamed.
    public var settingsURLCandidates: [String] {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ]
    }

    public var openSettingsButtonTitle: String {
        "Open \(paneDisplayName) Settings…"
    }
}

/// Pinned, truthful copy for the capability-aware permission model.
/// Statuses are shown ONLY from the real per-app probes
/// (`AXIsProcessTrusted`, `CGPreflightListenEventAccess`,
/// `AVCaptureDevice.authorizationStatus`) — never from a drag, an
/// intent, or a pref.
public enum HoldToTalkPermissionCopy: Sendable {
    /// Why the required capability is required (one sentence).
    public static func requirementExplanation(for shortcut: HoldToTalkShortcutKind) -> String {
        shortcut == .fn
            ? "Fn / Globe is a system key — only a listen-only key tap can see it while QuikCal is not frontmost, and macOS gates that tap behind Input Monitoring."
            : "Modifier holds are seen through a global event monitor that macOS gates behind Accessibility — Input Monitoring works too, because the key tap sees modifiers as well."
    }

    /// Blocked-start status (monitor `lastStatus` / Settings).
    public static func requiredNotGrantedStatus(for shortcut: HoldToTalkShortcutKind) -> String {
        shortcut == .fn
            ? "Hold-to-talk on Fn needs Input Monitoring. Open Input Monitoring settings, enable QuikCal, then Check again — typing still works."
            : "Hold-to-talk needs Accessibility (or Input Monitoring). Open its settings, enable QuikCal, then Check again — typing still works."
    }

    /// Mid-session revoke fail-safe status (capability-named, never
    /// mislabeling Input Monitoring as Accessibility).
    public static func revokedStatus(for shortcut: HoldToTalkShortcutKind) -> String {
        shortcut == .fn
            ? "Input Monitoring access was lost — hold-to-talk stopped. Re-enable it in System Settings, then Check again."
            : "Key-capture access was lost — hold-to-talk stopped. Re-enable Accessibility (or Input Monitoring) in System Settings, then Check again."
    }

    /// Granted verification copy — shown ONLY from the real per-app
    /// probe. Never claims tap creation == event delivery: actual Fn
    /// delivery is confirmed by the user's first real hold.
    public static func grantedStatus(for shortcut: HoldToTalkShortcutKind) -> String {
        shortcut == .fn
            ? "Input Monitoring granted — the Fn key tap is permitted. The first hold confirms delivery."
            : "Key-capture permission granted. The first hold confirms delivery."
    }

    /// Honest restart note for listen-access changes: a tap created
    /// BEFORE the grant may never deliver; macOS applies listen-access
    /// changes to newly launched event taps.
    public static let inputMonitoringRestartNote =
        "If Fn still doesn't register after granting, quit QuikCal from the menu bar and open it again — macOS applies listen-access changes to newly launched event taps."

    /// Dedicated onboarding permission step — title/copy reassessed to
    /// the actual capability (was "Accessibility" even for Fn).
    public static func stepTitle() -> String { "Permissions" }

    public static func stepSubtitle(for shortcut: HoldToTalkShortcutKind) -> String {
        shortcut == .fn
            ? "Input Monitoring lets QuikCal see the Fn hold. Skip anytime — typing always works."
            : "Accessibility lets QuikCal see the key hold globally (Input Monitoring works too). Skip anytime — typing always works."
    }

    /// Mic honesty note for the permission step — no request from the
    /// permission page, ever.
    public static let micRequestedOnHoldNote =
        "Microphone is requested on your first hold — never from this page."

    /// Screen & System Audio Recording honesty (advanced link only).
    public static let screenRecordingNotNeededNote =
        "No QuikCal feature records your screen or system audio — voice capture is microphone-only. This link is here for completeness."
}
