import Foundation

/// What opened the process or asked it to surface UI again.
///
/// Mounting a DMG is **not** an app launch — Finder only attaches a disk image.
/// QuikCal has no autorun / open-on-mount script.
public enum AppLaunchTrigger: String, Sendable, Equatable, CaseIterable {
    /// `applicationDidFinishLaunching` — process just started.
    case coldStart
    /// Finder / Spotlight / Dock reopen while the LSUIElement agent is already running
    /// (or macOS delivers reopen after a second open attempt).
    case applicationReopen
}

/// Window surface to present for a launch trigger. Capture itself is never a launch surface —
/// it is opened only by the menu-bar primary click or hold-to-talk.
public enum AppLaunchSurface: String, Sendable, Equatable, CaseIterable {
    /// Fresh install or incomplete journey (including mid-journey resume).
    case onboarding
    /// HEX-inspired configuration window (completed users on Finder/Spotlight reopen).
    case configuration
    /// Status item only — completed cold start; user opens capture via menu-bar click.
    case menuBarOnly
}

public enum StatusItemPrimaryAction: String, Sendable, Equatable {
    /// Left-click (and plain primary action) toggles the floating capture panel.
    case toggleCapture
}

public enum StatusItemSecondaryAction: String, Sendable, Equatable {
    /// Right-click / Control-click opens Settings + Quit (not capture).
    case statusMenu
}

/// Pure routing for first-run, resume, and reopen. Safe to unit-test without AppKit.
public enum AppLaunchRouter: Sendable {
    /// Routes cold start and application reopen.
    ///
    /// - Incomplete onboarding (`onboardingCompleted == false`), including a resume cursor:
    ///   always `.onboarding` for both triggers. Does **not** wipe prefs.
    /// - Completed users: cold start → menu bar only; reopen → configuration.
    /// - Upgrades never flip `onboardingCompleted` back to false.
    public static func surface(
        trigger: AppLaunchTrigger,
        onboardingCompleted: Bool
    ) -> AppLaunchSurface {
        if !onboardingCompleted {
            return .onboarding
        }
        switch trigger {
        case .coldStart:
            return .menuBarOnly
        case .applicationReopen:
            return .configuration
        }
    }

    /// Menu-bar primary click always opens/toggles capture — never configuration or onboarding.
    public static func statusItemPrimaryAction() -> StatusItemPrimaryAction {
        .toggleCapture
    }

    /// Secondary click is the Settings/Quit menu only.
    public static func statusItemSecondaryAction() -> StatusItemSecondaryAction {
        .statusMenu
    }

    /// Hold-to-talk / Fn must never be interpreted as “open configuration.”
    public static func holdToTalkOpensConfiguration() -> Bool {
        false
    }

    // MARK: Explicit status-menu setup reopen (manual path)

    /// What the status-menu "Start/Replay Setup…" item does. Manual reopen
    /// stays available in EVERY profile state — the automatic launch
    /// surface never removes it (2026-11-07 onboarding auto-launch repair:
    /// pinned here so the manual path is unit-testable, not AppKit glue).
    public enum StatusMenuSetupAction: String, Sendable, Equatable, CaseIterable {
        /// Incomplete journey: resume exactly where the cursor left off.
        case resumeIncompleteJourney
        /// Completed profile: explicit replay (resets ONLY completion +
        /// cursor — the same `beginOnboardingReplay` Settings uses).
        case replayCompletedSetup
    }

    /// The manual setup action for a profile state. Never resets prefs on
    /// its own — replay goes through the explicit `beginOnboardingReplay()`.
    public static func statusMenuSetupAction(onboardingCompleted: Bool) -> StatusMenuSetupAction {
        onboardingCompleted ? .replayCompletedSetup : .resumeIncompleteJourney
    }

    /// Menu-item title for the action — state-truthful (Start vs Replay).
    public static func statusMenuSetupTitle(for action: StatusMenuSetupAction) -> String {
        switch action {
        case .resumeIncompleteJourney: return "Start Setup…"
        case .replayCompletedSetup: return "Replay Setup…"
        }
    }

    // MARK: Readiness-aware launch routing (2026-11-07 owner correction)

    /// Routes cold start and reopen with the live essential-setup readiness.
    ///
    /// OWNER CORRECTION (2026-11-07, supersedes the installed-runtime
    /// repair's surfacing): onboarding runs ONCE, on initial setup — a
    /// COMPLETED profile NEVER auto-reopens the onboarding window on
    /// subsequent launches, even when optional setup is unready (the
    /// persisted hold-to-talk intent cannot work right now, or a Google
    /// destination has no linked account). The readiness input stays in
    /// the signature so launch diagnostics and the explicit Repair item
    /// keep their live gap verdict, but it no longer changes the surface.
    /// Explicit paths remain: the status-menu Start/Replay Setup item,
    /// Settings, and an explicit voice attempt.
    ///
    /// Incomplete profiles (including a deliberate mid-journey resume
    /// cursor) still open onboarding for both triggers — that is the
    /// initial setup this flow exists for, distinguishable from a
    /// completed profile by the persisted completion flag, never by
    /// readiness.
    public static func surface(
        trigger: AppLaunchTrigger,
        onboardingCompleted: Bool,
        readiness: EssentialSetupReadiness,
        context: AppLaunchContext
    ) -> AppLaunchSurface {
        guard onboardingCompleted else { return .onboarding }
        // Once-only: readiness/context never re-open onboarding for a
        // completed profile. They deliberately do not alter the surface.
        return surface(trigger: trigger, onboardingCompleted: onboardingCompleted)
    }

    /// The onboarding page a completed-but-unready state would resume at.
    /// OWNER CORRECTION (2026-11-07): launch routing no longer surfaces
    /// setup for completed profiles, so this is DIAGNOSTIC ONLY (the DEBUG
    /// QA launch probe dump reports which step the gap names). No
    /// production launch path opens a window from it anymore.
    public static func setupResumePage(gap: EssentialSetupGap) -> OnboardingPage {
        switch gap {
        case .googleDestinationSignedOut: return .calendar
        case .holdToTalkAccessibility: return .voiceSetup
        }
    }
}

/// Who or what initiated this process launch (2026-11-07 installed-runtime
/// repair). QuikCal registers NO login item / launch agent today, so every
/// production cold start is a direct user launch — but the distinction is
/// encoded here so a future autostart path can never nag: a background
/// launch with unready setup stays menu-bar-only.
public enum AppLaunchContext: String, Sendable, Equatable, CaseIterable {
    /// Finder / Spotlight / Dock — the user explicitly opened the app.
    case directUserLaunch
    /// Login item / launch agent autostart (none registered today).
    case backgroundAutostart
}

/// One essential-setup gap for a COMPLETED profile — only states the user
/// explicitly opted into. Intentional optional skips (hold-to-talk never
/// enabled or explicitly off; EventKit destination — the default, with or
/// without a selected calendar) NEVER create a gap, so finished users are
/// not nagged.
public enum EssentialSetupGap: String, Sendable, Equatable, CaseIterable {
    /// Persisted hold-to-talk intent is explicitly ON, but Accessibility is
    /// not trusted by THIS process right now (live probe, never a pref) —
    /// the user's 2026-11-07 observed case: intent flag ON, System Settings
    /// toggle ON, running process honestly untrusted.
    case holdToTalkAccessibility
    /// Google is the persisted destination (an explicit selection), but no
    /// active account is linked — prefs-only, decidable at launch without
    /// any Keychain read. Deeper Google readiness (tokens, target calendar)
    /// is intentionally NOT decided at launch: it needs off-main Keychain
    /// I/O and stays owned by Settings / the Add gate.
    case googleDestinationSignedOut
}

/// Essential-setup readiness verdict for a completed profile.
public enum EssentialSetupReadiness: Sendable, Equatable {
    /// Nothing essential is broken — the router's normal surface stands.
    case ready
    /// A user-opted-in capability cannot work right now.
    case unready(EssentialSetupGap)
}

/// Pure decision logic — no I/O, fully unit-testable. The app layer supplies
/// live inputs; every uncertain input fails toward NOT nagging (the manual
/// "Replay Setup…" path and Settings remain reachable in every state).
public enum EssentialSetupReadinessPolicy: Sendable {
    /// Gap precedence is deterministic: destination first (the write path),
    /// then hold-to-talk. A nil/empty Google account pointer is "signed out";
    /// a resolvable pointer is NOT a launch-time gap (bounded, prefs-only).
    public static func readiness(
        destinationKind: CalendarDestinationKind,
        googleActiveAccountID: String?,
        holdToTalkEnabledIntent: Bool?,
        accessibilityTrustedNow: Bool
    ) -> EssentialSetupReadiness {
        if destinationKind == .google,
           (googleActiveAccountID ?? "").isEmpty {
            return .unready(.googleDestinationSignedOut)
        }
        if holdToTalkEnabledIntent == true, !accessibilityTrustedNow {
            return .unready(.holdToTalkAccessibility)
        }
        return .ready
    }
}

/// Presentation contract for the targeted hold-to-talk repair card
/// (2026-11-07 launch-repair routing fix).
///
/// The repair card is NEVER presented automatically. Launch routing
/// (cold start, Finder/Spotlight reopen) and app activation present only
/// the router's own surface — never a permission-repair modal. This is
/// the fix for the 0.3.12 "compact repair card on every app open"
/// takeover: a completed profile whose persisted hold-to-talk intent
/// cannot work right now (Accessibility not trusted by the running
/// process) still cold-launches to the plain menu-bar surface, and the
/// user reaches permission setup through Voice setup, Settings, or an
/// explicit voice attempt.
///
/// The card opens ONLY from an explicit user action: the status-menu
/// Repair item (offered only while the live `LaunchReadinessRepairPolicy`
/// decision actually says repair) or the Settings hold-to-talk guide.
/// No persisted latch or suppression — the offer is recomputed from live
/// state every time.
public enum LaunchRepairPresentationPolicy: Sendable {
    /// Automatic presentation is forbidden for EVERY launch trigger —
    /// the router's own surface stands alone. (App activation is not a
    /// launch trigger, but the same rule holds there: no repair modal.)
    public static func presentsAutomaticallyOnLaunch(trigger: AppLaunchTrigger) -> Bool {
        false
    }

    /// The explicit status-menu Repair action is offered only while the
    /// live `LaunchReadinessRepairPolicy` decision says repair —
    /// truthful, intent-based, never a persisted suppression.
    public static func offersExplicitRepairAction(decision: LaunchReadinessRepair) -> Bool {
        decision == .repairHoldToTalkGuide
    }
}

/// Truthful, non-activating descriptions of speech and Apple Foundation Models.
/// Does not download the OS-managed generation model or request TCC prompts.
public enum SpeechParsingStatusCopy: Sendable {
    public static var builtInParser: String {
        "Built-in English parser — always on-device; clarifications fail closed (no invented dates/times)."
    }

    public static var appleFoundationModels: String {
        FoundationModelsReadiness.current.userFacingText
    }

    public static var speechEngine: String {
        "Local Parakeet via bundled QuietCalendarTranscribe (transcribe.cpp Metal) — not Apple Speech, not cloud."
    }

    public static func modelReadinessLabel(_ readiness: ParakeetModelReadiness) -> String {
        readiness.userFacingStatus
    }

    public static var accessibilityHoldNote: String {
        "Fn hold-to-talk needs Input Monitoring (the listen-only key tap that sees the Fn key); other shortcut keys need Accessibility — or Input Monitoring, which works too. Typing still works if permission is denied."
    }

    public static var parserDeterministicNote: String {
        "Event extraction uses Apple Foundation Models on-device when available; otherwise QuikCal uses its built-in parser. Every draft is reviewed before adding."
    }

    public static func microphoneAuthorizationLabel(_ raw: String) -> String {
        switch raw {
        case "authorized", "granted":
            return "Microphone: authorized (system default input when you hold-to-talk or tap mic)."
        case "denied", "restricted":
            return "Microphone: denied — typing still works. Re-enable in System Settings → Privacy & Security → Microphone."
        case "notDetermined":
            return "Microphone: not asked yet — QuikCal prompts only when you start capture (never at launch)."
        default:
            return "Microphone: \(raw)"
        }
    }
}
