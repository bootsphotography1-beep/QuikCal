import Foundation

// MARK: - Launch readiness repair (0.3.13)
//
// 2026-11-07 live evidence: a fresh 0.3.12 install did NOT offer onboarding —
// because `com.quietcalendar.app` prefs already carried
// `onboardingCompleted = 1` (same defaults domain ⇒ a reinstall is NOT fresh
// state). Routing for a completed profile is correct (cold → menu bar,
// reopen → Settings). Also live: Accessibility toggle ran ON in System
// Settings while the running process read trusted == no.
//
// What this policy adds is the bounded middle ground — for a COMPLETED
// profile whose explicitly-enabled hold-to-talk capability is stale-broken
// (intent on, trust currently no):
// - It never resets `onboardingCompleted` (a replay is still owner-triggered).
// - It never fires for an optional SKIPPED or disabled capability — the
//   intent flag distinguishes "user asked for this feature" from "user opted
//   out / never asked".
// - It DECIDES only that the targeted hold guide is warranted (no full
//   setup replay, no calendar/Google/model steps). Presentation is
//   EXPLICIT-ONLY (2026-11-07 launch-repair routing fix — see
//   `LaunchRepairPresentationPolicy`): the card is never presented
//   automatically on launch, reopen, or activation; it opens only from
//   the status-menu Repair item or the Settings hold guide, and it is
//   dismissible — it nudges, never forces a permission grant.
// - An incomplete profile stays owned by `AppLaunchRouter` (onboarding on
//   cold start AND reopen) — unchanged.

public enum LaunchReadinessRepair: Sendable, Equatable {
    /// Nothing required of the user; the router's normal surface stands.
    case none
    /// Completed profile + explicit hold-to-talk intent + Accessibility not
    /// trusted right now: present the targeted hold guide (repair surface).
    case repairHoldToTalkGuide
}

public enum LaunchReadinessRepairPolicy: Sendable {
    /// Async (e.g. off-main) trust refreshes may complete later; `trustedNow`
    /// is the freshest value available at decision time. Returning repair
    /// when actually trusted is impossible for callers that pass the live
    /// probe — the caller contract is the probe, never a pref.
    public static func decide(
        onboardingCompleted: Bool,
        holdToTalkEnabledIntent: Bool?,
        accessibilityTrustedNow: Bool
    ) -> LaunchReadinessRepair {
        guard onboardingCompleted else { return .none }
        // nil = never explicitly enabled (optional/skipped); false = the user
        // turned it off — both stay silent. Only an explicit ON intent that
        // cannot work right now is worth surfacing.
        guard holdToTalkEnabledIntent == true else { return .none }
        guard !accessibilityTrustedNow else { return .none }
        return .repairHoldToTalkGuide
    }
}

// MARK: - Practice detection honesty (0.3.13)
//
// The practice "Try it" button previously marked the hold as seen at button
// press time, so the status read "Released — nothing saved." WITHOUT any
// physical key having been detected (2026-11-07 screenshot evidence). These
// policies pin the honest behavior: the release must be an ACTUAL detected
// hold-release cycle delivered by the event monitor, and the page must
// distinguish "not listening yet (Accessibility off)" from "listening,
// waiting for you".

public enum PracticeDetectionPolicy: Sendable {
    /// Marks the practice as performed ONLY on a real detected release —
    /// a transition FROM `.holding` produced by the monitor, never the button
    /// press itself.
    public static func isDetectedRelease(
        previousPhase: HoldToTalkPhase,
        newPhase: HoldToTalkPhase
    ) -> Bool {
        previousPhase == .holding && newPhase != .holding
    }

    /// Status text for the practice page. `listenerInstalled` reflects real
    /// monitor installation; when it is off, the copy distinguishes WHY and
    /// never claims a grant that is not real (2026-11-07 parent fix — the
    /// permission checkpoint is now ON THIS PAGE, inline, so the old
    /// "previous step" wording was wrong in both directions):
    /// - Accessibility not trusted → point at the inline permission row above.
    /// - Trusted but the listener is not installed → hold-to-talk itself is
    ///   not enabled yet; never re-ask for a grant that already exists.
    public static func practiceStatusText(
        phase: HoldToTalkPhase,
        releaseDetected: Bool,
        listenerInstalled: Bool,
        accessibilityTrusted: Bool,
        shortcutName: String
    ) -> String {
        switch phase {
        case .holding:
            return "Holding… release to preview."
        case .releasing, .idle:
            if releaseDetected {
                return "Released — nothing saved."
            }
            if !listenerInstalled {
                if !accessibilityTrusted {
                    return "Enable Accessibility above, then check again."
                }
                return "Enable hold-to-talk, then try again."
            }
            return "Waiting for a hold…"
        }
    }
}
