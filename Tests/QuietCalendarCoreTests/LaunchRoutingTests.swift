import Testing
import Foundation
@testable import QuietCalendarCore

struct LaunchRoutingTests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Cold start

    @Test func freshInstallColdStartOpensOnboarding() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        #expect(prefs.onboardingCompleted == false)
        #expect(prefs.onboardingResume == nil)
        #expect(
            AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: prefs.onboardingCompleted)
            == .onboarding
        )
    }

    @Test func incompleteResumeColdStartOpensOnboardingNotSettings() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        prefs.saveOnboardingResume(OnboardingSessionState(page: .calendar, practiceNote: ""))
        #expect(prefs.onboardingCompleted == false)
        #expect(prefs.onboardingResume?.page == .calendar)
        #expect(
            AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false)
            == .onboarding
        )
        #expect(
            AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false)
            != .configuration
        )
    }

    @Test func completedColdStartIsMenuBarOnly() {
        #expect(
            AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true)
            == .menuBarOnly
        )
    }

    // MARK: Reopen (Finder / Spotlight)

    @Test func completedReopenOpensConfigurationNotCapture() {
        #expect(
            AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true)
            == .configuration
        )
    }

    @Test func incompleteReopenStillOnboarding() {
        #expect(
            AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: false)
            == .onboarding
        )
    }

    @Test func upgradeDoesNotResetCompletedFlag() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        prefs.onboardingCompleted = true
        prefs.glassIntensity = 0.55
        prefs.selectedCalendarID = "keep-me"
        // Simulating an upgrade: routing reads the existing flag; nothing flips it.
        #expect(prefs.onboardingCompleted == true)
        #expect(
            AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: prefs.onboardingCompleted)
            == .menuBarOnly
        )
        #expect(prefs.glassIntensity == 0.55)
        #expect(prefs.selectedCalendarID == "keep-me")
    }

    // MARK: Status item + hold

    @Test func statusItemPrimaryIsCaptureNeverConfig() {
        #expect(AppLaunchRouter.statusItemPrimaryAction() == .toggleCapture)
        #expect(AppLaunchRouter.statusItemSecondaryAction() == .statusMenu)
    }

    // MARK: Explicit status-menu setup reopen (manual path, 2026-11-07)

    @Test func manualSetupReopenResumesIncompleteJourney() {
        #expect(
            AppLaunchRouter.statusMenuSetupAction(onboardingCompleted: false)
            == .resumeIncompleteJourney
        )
        #expect(
            AppLaunchRouter.statusMenuSetupTitle(for: .resumeIncompleteJourney)
            == "Start Setup…"
        )
    }

    @Test func manualSetupReopenReplaysCompletedProfile() {
        #expect(
            AppLaunchRouter.statusMenuSetupAction(onboardingCompleted: true)
            == .replayCompletedSetup
        )
        #expect(
            AppLaunchRouter.statusMenuSetupTitle(for: .replayCompletedSetup)
            == "Replay Setup…"
        )
    }

    @Test func manualSetupReopenExistsInEveryProfileState() {
        // The manual path never depends on the automatic launch surface:
        // both actions are always reachable, whatever the router decided.
        for completed in [false, true] {
            #expect(
                AppLaunchRouter.statusMenuSetupAction(onboardingCompleted: completed)
                == (completed ? .replayCompletedSetup : .resumeIncompleteJourney)
            )
        }
    }

    @Test func holdToTalkNeverStealsIntoConfiguration() {
        #expect(AppLaunchRouter.holdToTalkOpensConfiguration() == false)
    }

    @Test func speechAndExtractionStatusCopyNamesOnDeviceAppleRuntime() {
        #expect(SpeechParsingStatusCopy.builtInParser.contains("Built-in"))
        #expect(SpeechParsingStatusCopy.parserDeterministicNote.contains("Apple Foundation Models"))
        #expect(SpeechParsingStatusCopy.speechEngine.contains("Parakeet"))
        #expect(SpeechParsingStatusCopy.speechEngine.contains("not Apple Speech"))
        #expect(SpeechParsingStatusCopy.microphoneAuthorizationLabel("notDetermined").contains("not asked"))
        #expect(SpeechParsingStatusCopy.microphoneAuthorizationLabel("denied").contains("denied"))
        #expect(SpeechParsingStatusCopy.accessibilityHoldNote.contains("Input Monitoring"))
        #expect(SpeechParsingStatusCopy.accessibilityHoldNote.contains("Fn"))
    }

    // MARK: Once-only onboarding (2026-11-07 OWNER CORRECTION)
    //
    // The owner corrected the 2026-11-07 installed-runtime surfacing:
    // onboarding runs ONCE, on initial setup. A COMPLETED profile NEVER
    // auto-reopens the onboarding window on subsequent launches — even
    // when its optional setup is unready (the exact owner-observed
    // state). Explicit Replay/Resume remains available from the status
    // menu and Settings; readiness stays live for diagnostics + the
    // explicit Repair item only.

    /// The owner's exact observed state (2026-11-07): legacy
    /// `onboardingCompleted` flag still set, EventKit destination,
    /// EXPLICIT hold-to-talk intent ON, Accessibility not trusted by the
    /// running process — readiness honestly reports the gap, but the
    /// launch surface stays menu-bar/config (once-only onboarding).
    @Test func userObservedCompletedButUnreadyNeverReopensOnboarding() {
        let readiness = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .eventKit,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        )
        #expect(readiness == .unready(.holdToTalkAccessibility))
        #expect(
            AppLaunchRouter.surface(
                trigger: .coldStart, onboardingCompleted: true,
                readiness: readiness, context: .directUserLaunch
            ) == .menuBarOnly
        )
        #expect(
            AppLaunchRouter.surface(
                trigger: .applicationReopen, onboardingCompleted: true,
                readiness: readiness, context: .directUserLaunch
            ) == .configuration
        )
        // The gap → step mapping stays available for diagnostics.
        #expect(AppLaunchRouter.setupResumePage(gap: .holdToTalkAccessibility) == .voiceSetup)
    }

    /// Fresh/incomplete profiles still open onboarding on every launch
    /// trigger — the initial-setup contract is unchanged, and a
    /// deliberate mid-journey resume keeps its cursor (distinguishable
    /// from a completed profile by the completion flag, never readiness).
    @Test func incompleteProfileStillOpensOnboardingOnEveryTrigger() {
        for readiness in [EssentialSetupReadiness.ready, .unready(.holdToTalkAccessibility)] {
            for context in AppLaunchContext.allCases {
                #expect(
                    AppLaunchRouter.surface(
                        trigger: .coldStart, onboardingCompleted: false,
                        readiness: readiness, context: context
                    ) == .onboarding
                )
                #expect(
                    AppLaunchRouter.surface(
                        trigger: .applicationReopen, onboardingCompleted: false,
                        readiness: readiness, context: context
                    ) == .onboarding
                )
            }
        }
    }

    /// The same persisted profile through the REAL prefs store — unready
    /// while the process is untrusted, ready again the moment trust
    /// returns (the flag alone never decides).
    @Test func ownerPersistedProfileFlipsWithLiveTrust() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        prefs.onboardingCompleted = true
        prefs.calendarDestinationKind = .eventKit
        prefs.selectedCalendarID = "20516F35-4857-4891-9041-61CB66E12C1B"
        prefs.holdToTalkMonitoringEnabled = true
        let unready = EssentialSetupReadinessPolicy.readiness(
            destinationKind: prefs.calendarDestinationKind,
            googleActiveAccountID: prefs.googleActiveAccountID,
            holdToTalkEnabledIntent: prefs.holdToTalkEnabledExplicit,
            accessibilityTrustedNow: false
        )
        #expect(unready == .unready(.holdToTalkAccessibility))
        let ready = EssentialSetupReadinessPolicy.readiness(
            destinationKind: prefs.calendarDestinationKind,
            googleActiveAccountID: prefs.googleActiveAccountID,
            holdToTalkEnabledIntent: prefs.holdToTalkEnabledExplicit,
            accessibilityTrustedNow: true
        )
        #expect(ready == .ready)
        // Trust restored → the finished profile is never nagged again.
        #expect(
            AppLaunchRouter.surface(
                trigger: .coldStart, onboardingCompleted: true,
                readiness: ready, context: .directUserLaunch
            ) == .menuBarOnly
        )
        #expect(
            AppLaunchRouter.surface(
                trigger: .applicationReopen, onboardingCompleted: true,
                readiness: ready, context: .directUserLaunch
            ) == .configuration
        )
    }

    /// Intentional optional skips never nag: hold-to-talk never enabled
    /// (nil) or explicitly off (false) stays ready even while untrusted.
    @Test func intentionalSkipsNeverNag() {
        for intent in [Bool?.none, false] {
            let readiness = EssentialSetupReadinessPolicy.readiness(
                destinationKind: .eventKit,
                googleActiveAccountID: nil,
                holdToTalkEnabledIntent: intent,
                accessibilityTrustedNow: false
            )
            #expect(readiness == .ready)
            #expect(
                AppLaunchRouter.surface(
                    trigger: .coldStart, onboardingCompleted: true,
                    readiness: readiness, context: .directUserLaunch
                ) == .menuBarOnly
            )
        }
    }

    /// EventKit is the default/optional destination — with or without a
    /// selected calendar it never creates a launch gap (the user may have
    /// intentionally skipped the calendar page).
    @Test func eventKitDestinationNeverCreatesALaunchGap() {
        let readiness = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .eventKit,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: false
        )
        #expect(readiness == .ready)
    }

    /// A background/login-item launch never surfaces setup, even when
    /// unready — the anti-nagging side of the 2026-11-07 repair. (Reopen
    /// is by definition a direct user action — Finder/Dock/Spotlight —
    /// so the background context only meaningfully applies to cold
    /// start; the impossible background+reopen combination falls back to
    /// the legacy configuration surface.)
    @Test func backgroundAutostartNeverSurfacesSetup() {
        let readiness = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .eventKit,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        )
        #expect(readiness == .unready(.holdToTalkAccessibility))
        #expect(
            AppLaunchRouter.surface(
                trigger: .coldStart, onboardingCompleted: true,
                readiness: readiness, context: .backgroundAutostart
            ) == .menuBarOnly
        )
        #expect(
            AppLaunchRouter.surface(
                trigger: .applicationReopen, onboardingCompleted: true,
                readiness: readiness, context: .backgroundAutostart
            ) == .configuration
        )
    }

    /// Google destination (an explicit selection) with no linked account
    /// still reports an honest gap for diagnostics — but the 2026-11-07
    /// owner correction keeps launch surfacing once-only: the completed
    /// profile stays menu-bar/config. A resolvable account is NOT a
    /// launch-time gap (bounded, prefs-only).
    @Test func googleDestinationSignedOutReportsGapWithoutReopeningOnboarding() {
        let signedOut = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .google,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: true
        )
        #expect(signedOut == .unready(.googleDestinationSignedOut))
        #expect(AppLaunchRouter.setupResumePage(gap: .googleDestinationSignedOut) == .calendar)
        #expect(
            AppLaunchRouter.surface(
                trigger: .coldStart, onboardingCompleted: true,
                readiness: signedOut, context: .directUserLaunch
            ) == .menuBarOnly
        )
        #expect(
            AppLaunchRouter.surface(
                trigger: .applicationReopen, onboardingCompleted: true,
                readiness: signedOut, context: .directUserLaunch
            ) == .configuration
        )
        let linked = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .google,
            googleActiveAccountID: "account-1",
            holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: true
        )
        #expect(linked == .ready)
        // An empty account pointer counts as signed out (stale/blank).
        let blank = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .google,
            googleActiveAccountID: "",
            holdToTalkEnabledIntent: false,
            accessibilityTrustedNow: true
        )
        #expect(blank == .unready(.googleDestinationSignedOut))
    }

    /// Gap precedence is deterministic: the destination (write path) gap
    /// wins over the hold-to-talk gap when both are unready.
    @Test func destinationGapTakesPrecedenceOverHoldGap() {
        let readiness = EssentialSetupReadinessPolicy.readiness(
            destinationKind: .google,
            googleActiveAccountID: nil,
            holdToTalkEnabledIntent: true,
            accessibilityTrustedNow: false
        )
        #expect(readiness == .unready(.googleDestinationSignedOut))
    }

    /// An incomplete profile keeps its own routing (and cursor) — the
    /// completed-but-unready machinery never touches it.
    @Test func incompleteProfileIgnoresReadinessMachinery() {
        for readiness in [EssentialSetupReadiness.ready, .unready(.holdToTalkAccessibility)] {
            for context in AppLaunchContext.allCases {
                #expect(
                    AppLaunchRouter.surface(
                        trigger: .coldStart, onboardingCompleted: false,
                        readiness: readiness, context: context
                    ) == .onboarding
                )
                #expect(
                    AppLaunchRouter.surface(
                        trigger: .applicationReopen, onboardingCompleted: false,
                        readiness: readiness, context: context
                    ) == .onboarding
                )
            }
        }
    }

    /// The legacy two-input routing contract is unchanged for ready
    /// completed profiles (every existing caller and test keeps its
    /// behavior; the readiness overload only ADDS the unready case).
    @Test func readyCompletedRoutingMatchesLegacyContract() {
        for trigger in AppLaunchTrigger.allCases {
            #expect(
                AppLaunchRouter.surface(
                    trigger: trigger, onboardingCompleted: true,
                    readiness: .ready, context: .directUserLaunch
                ) == AppLaunchRouter.surface(trigger: trigger, onboardingCompleted: true)
            )
        }
    }
}
