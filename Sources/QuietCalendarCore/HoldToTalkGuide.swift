import Foundation

/// Guided hold-to-talk setup phases (onboarding + Settings reopen).
/// User controls Back/Next/skip — never auto-advance solely from app reactivation.
public enum HoldToTalkGuidePhase: Int, Sendable, Codable, CaseIterable, Equatable, Comparable {
    case pickShortcut = 0
    case explainConflict = 1
    case accessibilityExplain = 2
    case openSettings = 3
    case recheckPermission = 4
    case enableMonitoring = 5
    case practiceHold = 6
    case done = 7

    public static func < (lhs: HoldToTalkGuidePhase, rhs: HoldToTalkGuidePhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .pickShortcut: return "Choose shortcut"
        case .explainConflict: return "About this key"
        case .accessibilityExplain: return "Accessibility"
        case .openSettings: return AccessibilityDragGuideCopy.guideTitle
        case .recheckPermission: return "Check permission"
        case .enableMonitoring: return "Enable hold-to-talk"
        case .practiceHold: return "Practice hold"
        case .done: return "Ready"
        }
    }

    public var next: HoldToTalkGuidePhase? {
        HoldToTalkGuidePhase(rawValue: rawValue + 1)
    }

    public var previous: HoldToTalkGuidePhase? {
        HoldToTalkGuidePhase(rawValue: rawValue - 1)
    }
}

public enum HoldPermissionRecheck: String, Sendable, Equatable, Codable {
    case unknown
    case denied
    case granted
    case skipped
}

/// Pure guide session — permission flags injected from AX / CG probes (never edited privately).
public struct HoldToTalkGuideState: Sendable, Equatable, Codable {
    public var phase: HoldToTalkGuidePhase
    public var shortcut: HoldToTalkShortcutKind
    public var accessibilityRecheck: HoldPermissionRecheck
    public var practiceHoldSeen: Bool
    public var practiceConfirmed: Bool
    /// True when opened from Settings without wiping other prefs / completion.
    public var settingsReopen: Bool

    public init(
        phase: HoldToTalkGuidePhase = .pickShortcut,
        shortcut: HoldToTalkShortcutKind = .fn,
        accessibilityRecheck: HoldPermissionRecheck = .unknown,
        practiceHoldSeen: Bool = false,
        practiceConfirmed: Bool = false,
        settingsReopen: Bool = false
    ) {
        self.phase = phase
        self.shortcut = shortcut
        self.accessibilityRecheck = accessibilityRecheck
        self.practiceHoldSeen = practiceHoldSeen
        self.practiceConfirmed = practiceConfirmed
        self.settingsReopen = settingsReopen
    }

    public mutating func goNext() {
        if let next = phase.next {
            phase = next
        }
    }

    public mutating func goBack() {
        if let previous = phase.previous {
            phase = previous
        }
    }

    public mutating func skipRemainder() {
        accessibilityRecheck = .skipped
        phase = .done
    }

    /// Apply a fresh Accessibility probe result (on reactivate / explicit Recheck).
    public mutating func applyAccessibilityTrusted(_ trusted: Bool) {
        accessibilityRecheck = trusted ? .granted : .denied
    }

    public mutating func markPracticeHoldSeen() {
        practiceHoldSeen = true
    }

    public mutating func confirmPractice() {
        practiceConfirmed = true
    }

    /// Hold while confirmation / practice must not mutate calendar drafts elsewhere.
    public static func practiceMayWriteCalendar() -> Bool { false }
}

/// Copy helpers — macOS-version-safe; never claim a Settings deep link always works.
public enum HoldToTalkGuideCopy: Sendable {
    public static func conflictExplanation(for shortcut: HoldToTalkShortcutKind) -> String {
        switch shortcut {
        case .fn:
            return "Fn / Globe is a system key on many Macs (dictation, input source, emoji). QuikCal does not change that system feature. If hold-to-talk fights with it, pick Option, Command, or Control instead."
        case .option:
            return "Option (⌥) as a global hold can conflict with Option-click menus and some app shortcuts. QuikCal only watches the key while hold-to-talk is enabled."
        case .command:
            return "Command (⌘) as a global hold can conflict with system and app shortcuts. Prefer it only if you rarely hold ⌘ alone."
        case .control:
            return "Control (⌃) as a global hold can conflict with Control-click and terminal shortcuts. Choose it deliberately."
        }
    }

    public static var accessibilityWhy: String {
        "Hold-to-talk needs one macOS privacy permission — Input Monitoring for the Fn key tap, Accessibility for other modifier keys."
    }

    public static var manualFallback: String {
        "Open Apple menu → System Settings → Privacy & Security → Accessibility, then enable QuikCal."
    }

    public static func recheckLabel(_ status: HoldPermissionRecheck) -> String {
        switch status {
        case .unknown: return "Not checked yet"
        case .denied: return "Not yet"
        case .granted: return "Granted"
        case .skipped: return "Skipped"
        }
    }

    /// One short sentence (owner, 2026-11-06): "Hold Fn, speak, then release."
    /// The key name comes from the shortcut kind, so the copy stays honest for
    /// every choice.
    public static func practiceHoldHint(for shortcut: HoldToTalkShortcutKind) -> String {
        "Hold \(shortcut.shortName), speak, then release."
    }

    /// Single concise note on the practice page — no large affirmations.
    public static let practiceNothingSavedNote = "Nothing is saved."

    public static var micVoiceTestNote: String {
        "Microphone permission is requested only if you start a voice test after the speech model is ready — never on this permission screen alone."
    }

    /// Preferred System Settings deep-link candidates (tried in order; failure → manual copy).
    public static var accessibilitySettingsURLCandidates: [String] {
        PrivacyPaneKind.accessibility.settingsURLCandidates
    }
}

/// Pure: which REAL macOS capability gates hold-to-talk capture for a
/// shortcut (2026-11-07 privacy repair). The previous model treated
/// Accessibility as always-required and Input Monitoring as a mere
/// optional extra; the launch-context experiment
/// (QUIKCAL-LIVE-AX-MISMATCH-20261107.md) proved tap CREATION succeeds
/// in an untrusted process, so the gate must be the capability that
/// governs event DELIVERY — never creation.
public enum HoldToTalkPermissionPolicy: Sendable {
    /// The capability that actually gates global capture for a shortcut:
    /// Fn/Globe is only seen globally by the listen-only CGEventTap →
    /// Input Monitoring (listen-event access). Other modifiers are
    /// captured by the global NSEvent monitor → Accessibility.
    public static func requiredCapability(for shortcut: HoldToTalkShortcutKind) -> HoldToTalkCapability {
        shortcut == .fn ? .inputMonitoring : .accessibility
    }

    /// May monitoring start? Fn needs Input Monitoring (only the
    /// listen-only tap sees Fn globally — creation without the grant
    /// delivers nothing). Other modifiers are captured by the
    /// AX-gated global NSEvent monitor OR the IM-gated tap, so EITHER
    /// capability suffices.
    public static func mayStartMonitoring(
        shortcut: HoldToTalkShortcutKind,
        accessibilityTrusted: Bool,
        inputMonitoringAllowed: Bool
    ) -> Bool {
        switch requiredCapability(for: shortcut) {
        case .inputMonitoring: return inputMonitoringAllowed
        case .accessibility: return accessibilityTrusted || inputMonitoringAllowed
        }
    }
}

/// Pure: launch/activation restore decisions for persisted hold-to-talk
/// intent (0.3.11). The persisted pref is the *intent*; the actual
/// `AXIsProcessTrusted()` probe is the only authority for whether
/// monitoring may really install. A pref alone never fakes "enabled".
public enum HoldToTalkLaunchPolicy: Sendable {
    /// Attempt to (re)install monitoring at launch or on app activation.
    /// Requires the user's persisted enabled intent, the shortcut's
    /// REQUIRED capability really granted right now (the live per-app
    /// probe is the only authority — a pref alone never fakes "enabled"),
    /// and monitors not already installed. An intentionally disabled
    /// choice (`enabledIntent == false`) never auto-starts; a missing
    /// required capability never auto-starts (it is reattempted on the
    /// next activation after the user grants it).
    public static func shouldAttemptRestore(
        enabledIntent: Bool?,
        requiredCapabilityGranted: Bool,
        monitoringInstalled: Bool
    ) -> Bool {
        enabledIntent == true && requiredCapabilityGranted && !monitoringInstalled
    }

    /// After a mic grant returns from the FIRST hold (which fired the system
    /// prompt as user intent): continue the CURRENT hold only if the key is
    /// still physically held (both monitor-derived phase AND the live HID
    /// modifier state — a release event swallowed while the system prompt had
    /// key focus must never leave a stale "holding" that auto-records) and
    /// the capture state is safe. Any other case — key released, confirmation
    /// screen open, speech already busy — requires the next hold. There is
    /// never an auto recording after a delayed grant or after the physical
    /// key release.
    public static func shouldContinueHoldAfterMicGrant(
        holdStillActive: Bool,
        keyPhysicallyDown: Bool,
        screenSafeForCapture: Bool,
        speechIdle: Bool
    ) -> Bool {
        holdStillActive && keyPhysicallyDown && screenSafeForCapture && speechIdle
    }
}
