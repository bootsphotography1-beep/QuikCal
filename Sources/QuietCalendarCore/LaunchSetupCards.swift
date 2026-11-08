import Foundation

/// Pure, unit-testable policy + pinned copy for the approved launch
/// setup/resume/repair cards (owner-approved Figma REV2.1, 2026-11-07,
/// nodes 7:330 / 7:349 / 7:385 — page "03 Launch & Resume").
///
/// Routing contract (unchanged by these cards):
/// - `AppLaunchRouter` still decides WHICH surface opens (incomplete →
///   onboarding on cold start AND reopen; completed → menu bar / Settings).
///   The cards are the OPENING CONTENT of the already-chosen onboarding
///   surface for launch-auto opens — never a new blocking window, never a
///   pref reset, never a change to completed-user routing.
/// - The targeted hold-guide repair card keeps `LaunchReadinessRepairPolicy`
///   semantics exactly (completed + explicit hold-to-talk intent +
///   Accessibility not trusted right now → compact, dismissible card;
///   no pref reset). Presentation is EXPLICIT-ONLY (2026-11-07
///   launch-repair routing fix): never automatic on launch/reopen/
///   activation — only the status-menu Repair item or the Settings
///   guide (`LaunchRepairPresentationPolicy`).
///
/// Honesty contract: the cards render REAL state only. The design's
/// "(example)" bullet values and the "Example values." caption are design
/// annotations and NEVER appear in the live UI; bullets/progress rows are
/// computed from the live profile at render time.
public enum LaunchSetupCardCopy: Sendable {
    // 7:330 — Setup needed (fresh)
    public static let setupNeededTitle = "QuikCal setup isn’t finished"
    public static let setupNeededSubtitle =
        "Finish setup to capture events from the menu bar. Your progress is saved."
    // 7:349 — Resume setup (returning)
    public static let resumeTitle = "Resume setup"
    public static let resumeSubtitle =
        "You’re partway through. Pick up where you left off — nothing is reset."
    // Actions (7:343/7:345, 7:368/7:370)
    public static let startSetupAction = "Start Setup"
    public static let resumeSetupAction = "Resume Setup"
    public static let openSettingsAction = "Open Settings"
}

/// One ✓/• progress row of the resume card (design 7:353–7:364).
/// `done` renders the green ✓; pending rows render the •.
public struct LaunchResumeProgressRow: Sendable, Equatable {
    public let title: String
    public let done: Bool

    public init(title: String, done: Bool) {
        self.title = title
        self.done = done
    }
}

/// Which launch card an incomplete profile sees (design 7:330 vs 7:349).
public enum LaunchSetupCardKind: Sendable, Equatable {
    /// Fresh journey (no progress past Welcome): what is missing, from
    /// live state.
    case setupNeeded(missing: [String])
    /// Returning journey (resume cursor past Welcome): real step progress.
    case resume(progress: [LaunchResumeProgressRow])
}

public enum LaunchSetupCardPolicy: Sendable {
    /// The resume card lists the capability pages between Welcome and
    /// Ready (2026-11-07 owner correction: the dedicated Accessibility
    /// step is its own page; Appearance is Settings-only).
    public static let progressStepTitles: [OnboardingPage: String] = [
        .calendar: "Calendar connection",
        .axPermission: "Accessibility",
        .voiceSetup: "Voice & hold-to-talk"
    ]

    /// True when the restored cursor is past Welcome → resume card (7:349);
    /// a cursor at Welcome (or absent) is a fresh journey → setup-needed
    /// card (7:330). No pref is read or written here — the caller passes
    /// the already-restored session cursor.
    public static func isResumeJourney(cursorPage: OnboardingPage) -> Bool {
        cursorPage != .welcome
    }

    /// Real missing-item bullets for the setup-needed card, computed from
    /// live state. Never hardcoded, never claiming readiness that is not
    /// true; the design's example bullets are only examples.
    public static func missingBullets(
        calendarConnected: Bool,
        modelsReady: Bool,
        googleDestination: Bool,
        googleConfigured: Bool,
        holdToTalkIntentExplicit: Bool,
        accessibilityTrusted: Bool
    ) -> [String] {
        var bullets: [String] = []
        if googleDestination && !googleConfigured {
            bullets.append("Google client configuration — not set up")
        }
        if !calendarConnected {
            bullets.append("Calendar — not connected yet")
        }
        if !modelsReady {
            bullets.append("Speech model — not downloaded yet")
        }
        if holdToTalkIntentExplicit && !accessibilityTrusted {
            bullets.append("Accessibility — Not yet")
        }
        if bullets.isEmpty {
            // Incomplete profile with every capability already in place:
            // the only honest remaining bullet is the flow itself.
            bullets.append("Only a few setup steps remain.")
        }
        return bullets
    }

    /// Real ✓/• progress rows from the live resume cursor. A page counts
    /// as done when the cursor has moved past it OR the user explicitly
    /// skipped it — both are real progress, never a faked ✓. Ordering
    /// follows the explicit FLOW order (`flowOrder`), not raw values.
    public static func progressRows(
        cursorPage: OnboardingPage,
        skipped: Set<OnboardingPage>
    ) -> [LaunchResumeProgressRow] {
        // flowOrder-based "past" comparison (raw values are frozen and no
        // longer monotonic with the walk order).
        let order: [OnboardingPage] = [.calendar, .axPermission, .voiceSetup]
        return order.map { page in
            LaunchResumeProgressRow(
                title: progressStepTitles[page] ?? page.title,
                done: page.flowIndex < cursorPage.flowIndex || skipped.contains(page)
            )
        }
    }

    /// Card kind for a restored launch session (pure; UI passes live state).
    public static func cardKind(
        cursorPage: OnboardingPage,
        skipped: Set<OnboardingPage>,
        calendarConnected: Bool,
        modelsReady: Bool,
        googleDestination: Bool,
        googleConfigured: Bool,
        holdToTalkIntentExplicit: Bool,
        accessibilityTrusted: Bool
    ) -> LaunchSetupCardKind {
        if isResumeJourney(cursorPage: cursorPage) {
            return .resume(progress: progressRows(cursorPage: cursorPage, skipped: skipped))
        }
        return .setupNeeded(missing: missingBullets(
            calendarConnected: calendarConnected,
            modelsReady: modelsReady,
            googleDestination: googleDestination,
            googleConfigured: googleConfigured,
            holdToTalkIntentExplicit: holdToTalkIntentExplicit,
            accessibilityTrusted: accessibilityTrusted
        ))
    }
}

/// Pinned copy for the targeted hold-guide repair card (design 7:385 —
/// "Targeted hold-guide repair (skippable, no resets)").
public enum HoldGuideRepairCardCopy: Sendable {
    public static let title = "Enable hold-to-talk"
    public static let subtitle = "Allow QuikCal to use your shortcut — nothing is reset."
    public static let statusLabel = "Accessibility"
    /// Chip when the live `AXIsProcessTrusted()` probe says not granted.
    public static let notYetChip = "Not yet"
    /// Chip when the live probe says granted (truthful, never a pref).
    public static let grantedChip = "Granted"
    public static let openSettingsAction = "Open Settings"
    public static let checkAgainAction = "Check again"
    public static let skipForNowAction = "Skip for now"
}
