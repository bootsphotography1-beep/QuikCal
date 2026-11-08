import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 owner correction pass: the dedicated Accessibility
/// verification step (its own onboarding page BEFORE voice practice) —
/// the pure state machine, bounded-poll contract, and the once-only
/// launch pins that fix "startup throws directly into voice setup".
struct OnboardingPermissionsFnRepairTests {

    // MARK: - Step phase machine (success only from a real probe)

    @Test func grantedComesOnlyFromATrustedProbe() {
        #expect(AXPermissionStepPolicy.probeResult(trusted: true) == .granted)
        #expect(AXPermissionStepPolicy.probeResult(trusted: false) == .notDetected)
    }

    @Test func dragEndNeverImpliesSuccessOnlyACheck() {
        // A drag ending (or beginning) never grants — it only triggers a
        // check; the drop itself is unobservable and never inferred.
        #expect(AXPermissionStepPolicy.phase(afterDragEnded: .waiting) == .checking)
        #expect(AXPermissionStepPolicy.phase(afterDragEnded: .idle) == .checking)
        // Terminal phases stay terminal — no drag can resurrect them.
        #expect(AXPermissionStepPolicy.phase(afterDragEnded: .granted) == .granted)
        #expect(AXPermissionStepPolicy.phase(afterDragEnded: .timedOut) == .timedOut)
    }

    @Test func openSettingsEntersTheBoundedWaitingWindow() {
        #expect(AXPermissionStepPolicy.phase(afterOpenSettingsTapped: .idle) == .waiting)
        #expect(AXPermissionStepPolicy.phase(afterOpenSettingsTapped: .notDetected) == .waiting)
    }

    @Test func appReturningChecksNeverAutoSucceeds() {
        #expect(AXPermissionStepPolicy.phase(afterAppReturned: .waiting) == .checking)
        #expect(AXPermissionStepPolicy.phase(afterAppReturned: .idle) == .checking)
        #expect(AXPermissionStepPolicy.phase(afterAppReturned: .granted) == .granted)
    }

    // MARK: - Bounded poll contract (only while the step is visible)

    @Test func pollingIsBoundedAndStopsOnTrust() {
        // Live phases poll, terminal ones never.
        #expect(AXPermissionStepPolicy.shouldPoll(phase: .waiting, elapsedWait: 0))
        #expect(AXPermissionStepPolicy.shouldPoll(phase: .checking, elapsedWait: 0))
        #expect(AXPermissionStepPolicy.shouldPoll(phase: .notDetected, elapsedWait: 0))
        #expect(!AXPermissionStepPolicy.shouldPoll(phase: .granted, elapsedWait: 0))
        #expect(!AXPermissionStepPolicy.shouldPoll(phase: .timedOut, elapsedWait: 0))
        // The bound is real: waiting beyond maxWaitSeconds stops polling.
        #expect(!AXPermissionStepPolicy.shouldPoll(
            phase: .waiting,
            elapsedWait: AXPermissionStepPolicy.maxWaitSeconds
        ))
        #expect(AXPermissionStepPolicy.pollIntervalSeconds >= 0.5)
        #expect(AXPermissionStepPolicy.maxWaitSeconds >= 60)
    }

    @Test func timeoutIsHonestNeverAUserFailureClaim() {
        // Before the bound: no timeout.
        #expect(AXPermissionStepPolicy.timeoutIfNeeded(
            phase: .waiting, elapsedWait: AXPermissionStepPolicy.maxWaitSeconds - 1
        ) == .waiting)
        // At/after the bound: the live window becomes timedOut.
        #expect(AXPermissionStepPolicy.timeoutIfNeeded(
            phase: .waiting, elapsedWait: AXPermissionStepPolicy.maxWaitSeconds
        ) == .timedOut)
        #expect(AXPermissionStepPolicy.timeoutIfNeeded(
            phase: .checking, elapsedWait: AXPermissionStepPolicy.maxWaitSeconds + 5
        ) == .timedOut)
        // Terminal phases are untouched.
        #expect(AXPermissionStepPolicy.timeoutIfNeeded(
            phase: .granted, elapsedWait: AXPermissionStepPolicy.maxWaitSeconds
        ) == .granted)
        // The timeout copy explains the honest actions (Check again +
        // quit/reopen) and never blames the user.
        #expect(AXPermissionStepCopy.timedOutCopy.contains("Check again"))
        #expect(AXPermissionStepCopy.timedOutCopy.lowercased().contains("quit"))
    }

    @Test func stepCopyNeverClaimsADragGrants() {
        #expect(AXPermissionStepCopy.dragDoesNotGrantNote.lowercased().contains("dragging"))
        #expect(AXPermissionStepCopy.dragDoesNotGrantNote.lowercased().contains("switch"))
        // Granted copy appears only with a real grant — and says so.
        #expect(AXPermissionStepCopy.grantedCopy.contains("granted"))
        #expect(AXPermissionStepCopy.stepSubtitle.lowercased().contains("skip"))
    }

    // MARK: - The dedicated page sits before voice practice

    @Test func accessibilityPagePrecedesVoicePractice() {
        #expect(OnboardingPage.axPermission.flowIndex < OnboardingPage.voiceSetup.flowIndex)
        #expect(OnboardingPage.calendar.next == .axPermission)
        #expect(OnboardingPage.axPermission.next == .voiceSetup)
        // A v2 resume snapshot on the new page round-trips (raw 4).
        let snapshot = OnboardingResumeSnapshot(page: .axPermission)
        let data = OnboardingResumeCodec.encode(snapshot)
        #expect(OnboardingResumeCodec.decode(data)?.page == .axPermission)
    }

    // MARK: - Once-only onboarding (owner correction, launch pins)

    /// The owner's exact repeated-launch state: completed + explicit hold
    /// intent + untrusted process. Every launch trigger stays OUT of
    /// onboarding — the fix for "startup throws directly into voice
    /// setup repeatedly".
    @Test func completedProfileNeverAutoOpensOnboardingOnAnyTrigger() {
        let unready = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .eventKit,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        )
        #expect(unready == .unready(.holdToTalkAccessibility))
        for trigger in AppLaunchTrigger.allCases {
            for context in AppLaunchContext.allCases {
                #expect(
                    AppLaunchRouter.surface(
                        trigger: trigger, onboardingCompleted: true,
                        readiness: unready, context: context
                    ) != .onboarding
                )
            }
        }
    }

    /// A fresh profile starts at WELCOME — never a jump into voice setup.
    @Test func freshProfileStartsAtWelcomeNeverVoice() {
        let suite = "quietcalendar.axrepair.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = AppPreferencesStore(defaults: defaults)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.makeOnboardingSession(forReplay: false).page == .welcome)
        // A deliberate incomplete resume keeps its cursor — distinct from
        // a completed profile (completion flag, never readiness).
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup))
        #expect(prefs.makeOnboardingSession(forReplay: false).page == .voiceSetup)
        #expect(prefs.onboardingCompleted == false)
    }
}
