import Foundation

/// Persisted preference keys for QuikCal.
///
/// Onboarding replay resets **`onboardingCompleted`** and clears the resume cursor.
/// Calendar selection, glass intensity, shortcut, and Google account metadata
/// are preserved unless the user changes them explicitly.
public enum AppPreferenceKey: Sendable {
    public static let selectedCalendarID = "quietCalendar.selectedCalendarID"
    /// When false/missing, the dedicated onboarding window is shown.
    public static let onboardingCompleted = "quietCalendar.onboardingCompleted"
    /// JSON `OnboardingResumeSnapshot` for interrupted first-run / mid-journey resume.
    public static let onboardingResumeJSON = "quietCalendar.onboardingResumeJSON"
    /// 0...1 glass intensity preference (material opacity scaling).
    public static let glassIntensity = "quietCalendar.glassIntensity"
    public static let holdToTalkShortcut = "quietCalendar.holdToTalkShortcut"
    /// 0.3.11: persisted hold-to-talk monitoring intent (tri-state).
    /// Missing = unknown (one-time migration decides); true = user enabled;
    /// false = user explicitly disabled. Never inferred except by the
    /// one-time migration in `migrateHoldToTalkEnabledIfUnknown()`.
    public static let holdToTalkEnabled = "quietCalendar.holdToTalkEnabled"
    public static let calendarDestinationKind = "quietCalendar.calendarDestinationKind"
    public static let googleAccountsJSON = "quietCalendar.googleAccountsJSON"
    public static let googleActiveAccountID = "quietCalendar.googleActiveAccountID"
    public static let panelDidCenterOnce = "quietCalendar.panelDidCenterOnce"
    /// Optional absolute path override for the Parakeet GGUF (otherwise Application Support default).
    public static let parakeetModelPath = "quietCalendar.parakeetModelPath"
    /// Settings “Show menu bar hint” rediscovery (0.3.2). Dismissing the
    /// coachmark never touches onboarding completion.
    public static let showMenuBarHint = "quietCalendar.showMenuBarHint"
}

public enum CalendarDestinationKind: String, Sendable, Codable, CaseIterable, Equatable {
    case eventKit
    case google
}

public enum HoldToTalkShortcutKind: String, Sendable, Codable, CaseIterable, Equatable {
    case fn
    case option
    case command
    case control

    public var displayName: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .option: return "Option (⌥)"
        case .command: return "Command (⌘)"
        case .control: return "Control (⌃)"
        }
    }

    /// Bare key name for terse practice copy: "Try Fn" / "Hold Fn".
    public var shortName: String {
        switch self {
        case .fn: return "Fn"
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        }
    }

    public var conflictNote: String {
        switch self {
        case .fn:
            return "Fn also acts as Globe on many Macs. QuikCal does not change that system setting; if hold-to-talk conflicts with dictation or input switching, pick another shortcut in Settings."
        case .option, .command, .control:
            return "Holding a modifier globally can conflict with other apps. Grant Accessibility/Input Monitoring only when you enable hold-to-talk."
        }
    }
}

/// Read/write helpers over UserDefaults for QuikCal preferences.
public struct AppPreferencesStore: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: AppPreferenceKey.onboardingCompleted) }
        nonmutating set { defaults.set(newValue, forKey: AppPreferenceKey.onboardingCompleted) }
    }

    /// Interrupted-journey cursor. Missing/corrupt → nil (start at welcome).
    public var onboardingResume: OnboardingResumeSnapshot? {
        get {
            OnboardingResumeCodec.decode(defaults.data(forKey: AppPreferenceKey.onboardingResumeJSON))
        }
        nonmutating set {
            if let newValue, let data = OnboardingResumeCodec.encode(newValue) {
                defaults.set(data, forKey: AppPreferenceKey.onboardingResumeJSON)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.onboardingResumeJSON)
            }
        }
    }

    public func saveOnboardingResume(_ session: OnboardingSessionState) {
        // Finished journeys clear the cursor; mid-completion step still resumes.
        if session.completed {
            clearOnboardingResume()
            return
        }
        onboardingResume = session.resumeSnapshot
    }

    public func clearOnboardingResume() {
        defaults.removeObject(forKey: AppPreferenceKey.onboardingResumeJSON)
    }

    /// 0.3.6: a completed user with a leftover resume cursor is stale state
    /// (e.g. a Settings hold-guide reopen persisted one after completion).
    /// Clear **only** the resume cursor; never other prefs/models/accounts.
    /// Incomplete journeys keep their cursor untouched.
    @discardableResult
    public func clearStaleResumeIfCompleted() -> Bool {
        guard onboardingCompleted,
              defaults.data(forKey: AppPreferenceKey.onboardingResumeJSON) != nil
        else { return false }
        clearOnboardingResume()
        return true
    }

    /// Loads session for window open: resume if incomplete journey exists; else welcome.
    public func makeOnboardingSession(forReplay: Bool) -> OnboardingSessionState {
        if forReplay {
            clearOnboardingResume()
            return .freshReplay()
        }
        if let resume = onboardingResume {
            return resume.makeSession(completed: false)
        }
        return OnboardingSessionState()
    }

    /// Resets completion + resume cursor so the next open shows onboarding from welcome.
    /// Does **not** touch calendar, glass, shortcut, or Google keys.
    public func resetOnboardingCompletion() {
        defaults.set(false, forKey: AppPreferenceKey.onboardingCompleted)
        clearOnboardingResume()
    }

    public var glassIntensity: Double {
        get {
            if defaults.object(forKey: AppPreferenceKey.glassIntensity) == nil {
                return 0.72
            }
            return min(1, max(0, defaults.double(forKey: AppPreferenceKey.glassIntensity)))
        }
        nonmutating set {
            defaults.set(min(1, max(0, newValue)), forKey: AppPreferenceKey.glassIntensity)
        }
    }

    public var holdToTalkShortcut: HoldToTalkShortcutKind {
        get {
            let raw = defaults.string(forKey: AppPreferenceKey.holdToTalkShortcut) ?? HoldToTalkShortcutKind.fn.rawValue
            return HoldToTalkShortcutKind(rawValue: raw) ?? .fn
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: AppPreferenceKey.holdToTalkShortcut)
        }
    }

    // MARK: Hold-to-talk monitoring intent (0.3.11 launch persistence)

    /// The explicit stored intent with NO migration side effects.
    /// `nil` = the user never made (or inherited) an on/off choice.
    public var holdToTalkEnabledExplicit: Bool? {
        if defaults.object(forKey: AppPreferenceKey.holdToTalkEnabled) == nil { return nil }
        return defaults.bool(forKey: AppPreferenceKey.holdToTalkEnabled)
    }

    /// One-time backward-compatible migration. Pre-0.3.11 builds never
    /// persisted monitoring at all (it silently died on relaunch), so there
    /// is nothing to read. Infer "enabled" ONLY where actual prior settings
    /// show completed shortcut setup: onboarding finished AND the shortcut
    /// key was explicitly written by the hold guide (skipping the guide
    /// never writes it). Everyone else inherits "off" — the same behavior
    /// they had after every relaunch before this fix. The inferred value is
    /// persisted once so it becomes the durable setting; an explicit
    /// true/false is never overridden.
    @discardableResult
    public func migrateHoldToTalkEnabledIfUnknown() -> Bool {
        if defaults.object(forKey: AppPreferenceKey.holdToTalkEnabled) != nil {
            return defaults.bool(forKey: AppPreferenceKey.holdToTalkEnabled)
        }
        let inferred = onboardingCompleted
            && defaults.object(forKey: AppPreferenceKey.holdToTalkShortcut) != nil
        defaults.set(inferred, forKey: AppPreferenceKey.holdToTalkEnabled)
        return inferred
    }

    /// The effective enabled intent, running the one-time migration when the
    /// key is unknown. Launch-time restore reads through this.
    public var holdToTalkMonitoringEnabled: Bool {
        get {
            if defaults.object(forKey: AppPreferenceKey.holdToTalkEnabled) == nil {
                return migrateHoldToTalkEnabledIfUnknown()
            }
            return defaults.bool(forKey: AppPreferenceKey.holdToTalkEnabled)
        }
        nonmutating set {
            defaults.set(newValue, forKey: AppPreferenceKey.holdToTalkEnabled)
        }
    }

    public var calendarDestinationKind: CalendarDestinationKind {
        get {
            let raw = defaults.string(forKey: AppPreferenceKey.calendarDestinationKind) ?? CalendarDestinationKind.eventKit.rawValue
            return CalendarDestinationKind(rawValue: raw) ?? .eventKit
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: AppPreferenceKey.calendarDestinationKind)
        }
    }

    public var selectedCalendarID: String? {
        get { defaults.string(forKey: AppPreferenceKey.selectedCalendarID) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: AppPreferenceKey.selectedCalendarID)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.selectedCalendarID)
            }
        }
    }

    public var googleActiveAccountID: String? {
        get { defaults.string(forKey: AppPreferenceKey.googleActiveAccountID) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: AppPreferenceKey.googleActiveAccountID)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.googleActiveAccountID)
            }
        }
    }

    public var parakeetModelPath: String? {
        get { defaults.string(forKey: AppPreferenceKey.parakeetModelPath) }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: AppPreferenceKey.parakeetModelPath)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.parakeetModelPath)
            }
        }
    }

    /// Set by Settings when the user asks to see the menu-bar hint again.
    public var showMenuBarHint: Bool {
        get { defaults.bool(forKey: AppPreferenceKey.showMenuBarHint) }
        nonmutating set { defaults.set(newValue, forKey: AppPreferenceKey.showMenuBarHint) }
    }

    public func resolveParakeetModelURL(fileManager: FileManager = .default) -> URL {        ParakeetRuntimeLocator.resolveModelURL(
            overridePath: parakeetModelPath,
            fileManager: fileManager
        )
    }

    public func parakeetModelValidation(
        requireChecksum: Bool = false,
        fileManager: FileManager = .default
    ) -> ParakeetModelValidation {
        ParakeetModelValidator.validate(
            fileURL: resolveParakeetModelURL(fileManager: fileManager),
            requireChecksum: requireChecksum,
            fileManager: fileManager
        )
    }
}
