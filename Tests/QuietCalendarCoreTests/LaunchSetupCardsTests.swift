import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 launch setup/resume/repair cards (owner-approved Figma REV2.1,
/// nodes 7:330 / 7:349 / 7:385 — page "03 Launch & Resume"). Pure policy
/// tests — no GUI, no network, no TCC, no pref mutation. These pin:
/// - the exact approved card copy (no invented strings),
/// - honest bullets/progress computed from live state (never the design's
///   "(example)" values, never the "Example values." annotation),
/// - the routing contract: card KIND follows the real cursor, and the
///   policy layer has no pref access at all (no-reset by construction).
struct LaunchSetupCardsTests {

    // MARK: - Approved copy (design 7:330 / 7:349)

    @Test func setupNeededCopyMatchesDesign() {
        #expect(LaunchSetupCardCopy.setupNeededTitle == "QuikCal setup isn’t finished")
        #expect(LaunchSetupCardCopy.setupNeededSubtitle
            == "Finish setup to capture events from the menu bar. Your progress is saved.")
        #expect(LaunchSetupCardCopy.startSetupAction == "Start Setup")
    }

    @Test func resumeCopyMatchesDesign() {
        #expect(LaunchSetupCardCopy.resumeTitle == "Resume setup")
        #expect(LaunchSetupCardCopy.resumeSubtitle
            == "You’re partway through. Pick up where you left off — nothing is reset.")
        #expect(LaunchSetupCardCopy.resumeSetupAction == "Resume Setup")
    }

    @Test func sharedActionCopyMatchesDesign() {
        #expect(LaunchSetupCardCopy.openSettingsAction == "Open Settings")
    }

    @Test func noDeveloperAnnotationsLeakIntoLiveCardCopy() {
        // The design's "(example)" bullets and its "Example values."
        // caption are annotations — they must never ship in live copy.
        let allCopy = [
            LaunchSetupCardCopy.setupNeededTitle, LaunchSetupCardCopy.setupNeededSubtitle,
            LaunchSetupCardCopy.resumeTitle, LaunchSetupCardCopy.resumeSubtitle,
            LaunchSetupCardCopy.startSetupAction, LaunchSetupCardCopy.resumeSetupAction,
            LaunchSetupCardCopy.openSettingsAction,
            HoldGuideRepairCardCopy.title, HoldGuideRepairCardCopy.subtitle,
            HoldGuideRepairCardCopy.statusLabel, HoldGuideRepairCardCopy.notYetChip,
            HoldGuideRepairCardCopy.grantedChip, HoldGuideRepairCardCopy.openSettingsAction,
            HoldGuideRepairCardCopy.checkAgainAction, HoldGuideRepairCardCopy.skipForNowAction
        ]
        for text in allCopy {
            #expect(!text.lowercased().contains("example"))
            #expect(!text.lowercased().contains("(fixture)"))
            #expect(!text.lowercased().contains("todo"))
        }
        // No bullet the policy can produce mentions the annotation either.
        let everyBullet = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: false, modelsReady: false,
            googleDestination: true, googleConfigured: false,
            holdToTalkIntentExplicit: true, accessibilityTrusted: false
        )
        for bullet in everyBullet {
            #expect(!bullet.lowercased().contains("example values"))
        }
    }

    // MARK: - Card kind follows the real cursor (routing contract)

    @Test func freshJourneyAtWelcomeIsSetupNeeded() {
        #expect(!LaunchSetupCardPolicy.isResumeJourney(cursorPage: .welcome))
    }

    @Test func cursorPastWelcomeIsResume() {
        for page in OnboardingPage.allCases where page != .welcome {
            #expect(LaunchSetupCardPolicy.isResumeJourney(cursorPage: page))
        }
    }

    @Test func cardKindForFreshJourneyIsSetupNeededWithRealBullets() {
        guard case .setupNeeded(let missing) = LaunchSetupCardPolicy.cardKind(
            cursorPage: .welcome, skipped: [],
            calendarConnected: false, modelsReady: false,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        ) else {
            Issue.record("expected setupNeeded")
            return
        }
        #expect(missing == ["Calendar — not connected yet", "Speech model — not downloaded yet"])
    }

    @Test func cardKindForReturningJourneyIsResumeWithRealProgress() {
        guard case .resume(let rows) = LaunchSetupCardPolicy.cardKind(
            cursorPage: .calendar, skipped: [],
            calendarConnected: false, modelsReady: false,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        ) else {
            Issue.record("expected resume")
            return
        }
        // 2026-11-07 owner correction: three capability rows (the
        // dedicated Accessibility step is its own page), cursor at Calendar.
        #expect(rows.map(\.title) == ["Calendar connection", "Accessibility", "Voice & hold-to-talk"])
        #expect(rows.map(\.done) == [false, false, false])
    }

    // MARK: - Honest bullets from live state (design 7:333)

    @Test func freshEventKitUserSeesCalendarAndModelBullets() {
        let bullets = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: false, modelsReady: false,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        )
        #expect(bullets.contains("Calendar — not connected yet"))
        #expect(bullets.contains("Speech model — not downloaded yet"))
        #expect(!bullets.contains("Google client configuration — not set up"))
        #expect(!bullets.contains("Accessibility — Not yet"))
    }

    @Test func googleDestinationWithoutConfigHasTheGoogleBullet() {
        let bullets = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: true, modelsReady: true,
            googleDestination: true, googleConfigured: false,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        )
        #expect(bullets == ["Google client configuration — not set up"])
    }

    @Test func explicitHoldIntentWithoutTrustHasTheAccessibilityBullet() {
        let bullets = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: true, modelsReady: true,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: true, accessibilityTrusted: false
        )
        #expect(bullets == ["Accessibility — Not yet"])
        // Trusted right now → no stale "Not yet" bullet.
        let trusted = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: true, modelsReady: true,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: true, accessibilityTrusted: true
        )
        #expect(!trusted.contains("Accessibility — Not yet"))
    }

    @Test func skippedOptionalHoldIntentNeverShowsTheAccessibilityBullet() {
        // nil/false intent = optional or turned off — never nagged on the card.
        for intent in [nil, false] {
            let bullets = LaunchSetupCardPolicy.missingBullets(
                calendarConnected: true, modelsReady: true,
                googleDestination: false, googleConfigured: true,
                holdToTalkIntentExplicit: intent == true, accessibilityTrusted: false
            )
            #expect(!bullets.contains("Accessibility — Not yet"))
        }
    }

    @Test func everythingReadyStillTellsTheTruthWithAFallbackBullet() {
        let bullets = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: true, modelsReady: true,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        )
        #expect(bullets == ["Only a few setup steps remain."])
    }

    @Test func bulletsNeverClaimReadinessThatIsNotTrue() {
        // No bullet may state a capability is set up when its input is false.
        let bullets = LaunchSetupCardPolicy.missingBullets(
            calendarConnected: false, modelsReady: false,
            googleDestination: false, googleConfigured: true,
            holdToTalkIntentExplicit: false, accessibilityTrusted: false
        )
        for bullet in bullets {
            if bullet.contains("connected") {
                #expect(bullet.contains("not connected"))
            }
            if bullet.lowercased().contains("downloaded") {
                #expect(bullet.contains("not downloaded"))
            }
        }
    }

    // MARK: - Real ✓/• progress rows (design 7:352)

    @Test func progressRowsFollowTheRealPageOrder() {
        let rows = LaunchSetupCardPolicy.progressRows(cursorPage: .welcome, skipped: [])
        #expect(rows.map(\.title) == ["Calendar connection", "Accessibility", "Voice & hold-to-talk"])
        #expect(rows.allSatisfy { !$0.done })
    }

    @Test func cursorMarksPastPagesDoneAndLaterPagesPending() {
        let rows = LaunchSetupCardPolicy.progressRows(cursorPage: .voiceSetup, skipped: [])
        // Flow order (axPermission walks BEFORE voiceSetup even though
        // its raw value is higher) — done is flowIndex-based.
        #expect(rows.map(\.done) == [true, true, false])
    }

    @Test func explicitlySkippedPagesCountAsPastNotFaked() {
        // A skipped page is real progress the user made a real choice about.
        let rows = LaunchSetupCardPolicy.progressRows(cursorPage: .ready, skipped: [.voiceSetup])
        #expect(rows.map(\.done) == [true, true, true])
    }

    // MARK: - Targeted repair card copy (design 7:385)

    @Test func repairCardCopyMatchesDesign() {
        #expect(HoldGuideRepairCardCopy.title == "Enable hold-to-talk")
        #expect(HoldGuideRepairCardCopy.subtitle == "Allow QuikCal to use your shortcut — nothing is reset.")
        #expect(HoldGuideRepairCardCopy.statusLabel == "Accessibility")
        #expect(HoldGuideRepairCardCopy.notYetChip == "Not yet")
        #expect(HoldGuideRepairCardCopy.grantedChip == "Granted")
        #expect(HoldGuideRepairCardCopy.openSettingsAction == "Open Settings")
        #expect(HoldGuideRepairCardCopy.checkAgainAction == "Check again")
        #expect(HoldGuideRepairCardCopy.skipForNowAction == "Skip for now")
    }

    @Test func repairCardNeverClaimsAResetOrAGrant() {
        // The subtitle is the no-reset promise; no copy may claim the app
        // grants Accessibility itself.
        let copy = HoldGuideRepairCardCopy.subtitle + HoldGuideRepairCardCopy.title
            + HoldGuideRepairCardCopy.skipForNowAction
        #expect(copy.contains("nothing is reset"))
        #expect(!copy.lowercased().contains("granted automatically"))
        #expect(!copy.lowercased().contains("we'll enable"))
    }

    // MARK: - Launch repair policy stays the card's only trigger

    @Test func repairDecisionIsUnchangedByTheCardPass() {
        // Same contract the 0.3.13 targeted repair shipped with: only a
        // COMPLETED profile with an EXPLICIT on-intent that cannot work
        // right now triggers the repair surface. The card changes the
        // presented visual only — never this decision.
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: false, holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: nil,
            accessibilityTrustedNow: false) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: false) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: true) == .none)
        #expect(LaunchReadinessRepairPolicy.decide(
            onboardingCompleted: true, holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false) == .repairHoldToTalkGuide)
    }

    // MARK: - Launch routing surfaces are untouched by the cards

    @Test func launchRouterStillRoutesIncompleteToOnboardingForBothTriggers() {
        // The cards are CONTENT of the onboarding surface, not new routing:
        // incomplete → onboarding on cold start AND reopen (unchanged),
        // completed → menu bar (cold) / configuration (reopen) (unchanged).
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false) == .onboarding)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: false) == .onboarding)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true) == .menuBarOnly)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true) == .configuration)
    }

    @Test func holdToTalkNeverOpensConfigurationOrOnboarding() {
        #expect(!AppLaunchRouter.holdToTalkOpensConfiguration())
    }
}
