import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 launch-repair routing fix — regression matrix.
///
/// Owner evidence: every app open showed the compact "Enable
/// hold-to-talk / Accessibility Not yet" repair card instead of a normal
/// launch. Root cause: `applicationDidFinishLaunching` presented the
/// targeted repair card automatically whenever the completed profile's
/// persisted hold-to-talk intent could not work right now (Accessibility
/// not trusted by the running process). The fix removes EVERY automatic
/// presentation path (cold start, reopen, activation) — the card opens
/// only from the explicit status-menu Repair item or the Settings hold
/// guide, and the pure `LaunchReadinessRepairPolicy` decision itself is
/// unchanged (still honest about the broken state).
struct LaunchRepairPresentationTests {

    // MARK: - Automatic presentation is forbidden on every launch trigger

    @Test func automaticRepairPresentationIsForbiddenForEveryTrigger() {
        for trigger in AppLaunchTrigger.allCases {
            #expect(
                LaunchRepairPresentationPolicy.presentsAutomaticallyOnLaunch(trigger: trigger) == false,
                "automatic repair presentation must be forbidden for \(trigger)"
            )
        }
    }

    /// The full state matrix × every trigger: no combination of
    /// completion / hold intent / live trust may ever produce an
    /// AUTOMATIC repair presentation — the router's own surface stands
    /// alone in every case.
    @Test func noStateCombinationEverProducesAutomaticPresentation() {
        for trigger in AppLaunchTrigger.allCases {
            for completed in [true, false] {
                for intent in [true, false, nil] as [Bool?] {
                    for trusted in [true, false] {
                        #expect(
                            LaunchRepairPresentationPolicy.presentsAutomaticallyOnLaunch(trigger: trigger) == false
                        )
                        // The router's own surface is unchanged by the fix:
                        #expect(
                            AppLaunchRouter.surface(trigger: trigger, onboardingCompleted: completed)
                                != AppLaunchSurface.menuBarOnly || completed
                        )
                    }
                }
            }
        }
    }

    // MARK: - The pure repair decision is unchanged (honesty preserved)

    /// Only completed + explicitly-enabled intent + live-untrusted says
    /// repair. Every other combination — including every incomplete
    /// profile — stays `.none`. This pins that the fix removed the
    /// TAKEOVER, not the honest detection: the state is still reported
    /// as broken; it just no longer hijacks the launch.
    @Test func repairDecisionMatrixUnchanged() {
        // The one warranted state:
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: true, accessibilityTrustedNow: false
        ) == .repairHoldToTalkGuide)
        // Trust present → nothing to repair:
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: true, accessibilityTrustedNow: true
        ) == .none)
        // Optional/skipped (nil) or explicitly disabled (false) → silent:
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: nil, accessibilityTrustedNow: false
        ) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: false, accessibilityTrustedNow: false
        ) == .none)
        // Incomplete profile is owned by AppLaunchRouter — never a repair:
        for intent in [true, false, nil] as [Bool?] {
            for trusted in [true, false] {
                #expect(LaunchReadinessRepairPolicy.decide(
                    onboardingCompleted: false, holdToTalkEnabledIntent: intent, accessibilityTrustedNow: trusted
                ) == .none)
            }
        }
    }

    // MARK: - Incomplete profile: onboarding only, never a repair card over it

    @Test func incompleteProfileRoutesToOnboardingWithoutRepairSurface() {
        for trigger in AppLaunchTrigger.allCases {
            #expect(
                AppLaunchRouter.surface(trigger: trigger, onboardingCompleted: false) == .onboarding
            )
            // And the repair decision for the same state is silent, so no
            // repair card may replace/overlay the onboarding window:
            #expect(LaunchReadinessRepairPolicy.decide(
                onboardingCompleted: false, holdToTalkEnabledIntent: true, accessibilityTrustedNow: false
            ) == .none)
        }
    }

    // MARK: - Launch routing itself is unchanged (no unrelated refactor)

    @Test func launchRoutingMatrixUnchangedByTheFix() {
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false) == .onboarding)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: false) == .onboarding)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true) == .menuBarOnly)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true) == .configuration)
    }

    // MARK: - Explicit repair entry stays truthful and gated

    /// The status-menu Repair item is offered ONLY while the live
    /// decision actually says repair — never a persisted latch, never a
    /// permanent menu fixture, never offered when nothing is broken.
    @Test func explicitRepairActionOfferedOnlyWhileWarranted() {
        #expect(LaunchRepairPresentationPolicy.offersExplicitRepairAction(decision: .repairHoldToTalkGuide) == true)
        #expect(LaunchRepairPresentationPolicy.offersExplicitRepairAction(decision: .none) == false)
    }

    /// The explicit voice path is not weakened by the fix: a pref NEVER
    /// fakes trust — an untrusted process never silently restores
    /// monitoring (the user is guided explicitly instead), and a hold
    /// still never opens configuration.
    @Test func explicitVoiceGatingUnchanged() {
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: true, monitoringInstalled: false) == true)
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: false, monitoringInstalled: false) == false)
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: false, requiredCapabilityGranted: true, monitoringInstalled: false) == false)
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: nil, requiredCapabilityGranted: true, monitoringInstalled: false) == false)
        #expect(AppLaunchRouter.holdToTalkOpensConfiguration() == false)
    }

    // MARK: - Repair card copy stays truthful (no cosmetic hiding of "Not yet")

    @Test func repairCardCopyStaysTruthful() {
        #expect(HoldGuideRepairCardCopy.notYetChip == "Not yet")
        #expect(HoldGuideRepairCardCopy.grantedChip == "Granted")
        #expect(HoldGuideRepairCardCopy.title == "Enable hold-to-talk")
        #expect(HoldGuideRepairCardCopy.skipForNowAction == "Skip for now")
    }
}
