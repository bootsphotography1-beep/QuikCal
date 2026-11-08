import Testing
import Foundation
@testable import QuietCalendarCore

struct PreferencesShortcutOAuthTests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultGlassAndOnboardingIncomplete() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        #expect(prefs.onboardingCompleted == false)
        #expect(prefs.glassIntensity == 0.72)
        #expect(prefs.holdToTalkShortcut == .fn)
        #expect(prefs.calendarDestinationKind == .eventKit)
    }

    @Test func onboardingPersistenceAndResetOnlyCompletionKey() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.glassIntensity = 0.4
        prefs.selectedCalendarID = "cal-keep"
        prefs.holdToTalkShortcut = .option
        prefs.onboardingResume = OnboardingResumeSnapshot(page: .voiceSetup, practiceNote: "keep?")
        #expect(prefs.onboardingCompleted == true)

        prefs.resetOnboardingCompletion()
        #expect(prefs.onboardingCompleted == false)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.glassIntensity == 0.4)
        #expect(prefs.selectedCalendarID == "cal-keep")
        #expect(prefs.holdToTalkShortcut == .option)
        #expect(defaults.object(forKey: AppPreferenceKey.onboardingCompleted) as? Bool == false)
        #expect(defaults.data(forKey: AppPreferenceKey.onboardingResumeJSON) == nil)
    }

    @Test func onboardingResumePersistsBackSkipAndPracticeNote() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        var session = OnboardingSessionState()
        session.goNext() // calendar
        session.skipCurrent() // skip calendar → axPermission (2026-11-07 dedicated step)
        session.skipCurrent() // skip axPermission → voiceSetup
        session.practiceNote = "Lunch Friday at noon"
        prefs.saveOnboardingResume(session)

        let restored = prefs.makeOnboardingSession(forReplay: false)
        #expect(restored.page == .voiceSetup)
        #expect(restored.skipped.contains(.calendar))
        #expect(restored.skipped.contains(.axPermission))
        #expect(restored.practiceNote == "Lunch Friday at noon")
        #expect(restored.completed == false)

        // Back from voiceSetup → the Accessibility step (the step before it)
        var navigated = restored
        navigated.goBack()
        #expect(navigated.page == .axPermission)
        prefs.saveOnboardingResume(navigated)
        #expect(prefs.onboardingResume?.page == .axPermission)
    }

    @Test func onboardingReplayStartsFreshWithoutWipingOtherPrefs() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.glassIntensity = 0.33
        prefs.selectedCalendarID = "cal-keep"
        prefs.calendarDestinationKind = .google
        let session = OnboardingSessionState(page: .voiceSetup, practiceNote: "stale")
        prefs.saveOnboardingResume(session)
        prefs.onboardingCompleted = true

        prefs.resetOnboardingCompletion()
        let replay = prefs.makeOnboardingSession(forReplay: true)
        #expect(replay.page == .welcome)
        #expect(replay.practiceNote.isEmpty)
        #expect(replay.skipped.isEmpty)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.glassIntensity == 0.33)
        #expect(prefs.selectedCalendarID == "cal-keep")
        #expect(prefs.calendarDestinationKind == .google)
    }

    @Test func onboardingFinishClearsResumeCursor() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        var session = OnboardingSessionState(page: .ready)
        prefs.saveOnboardingResume(session)
        #expect(prefs.onboardingResume?.page == .ready)
        session.finish()
        prefs.saveOnboardingResume(session)
        #expect(prefs.onboardingResume == nil)
        #expect(session.completed)
    }

    @Test func onboardingResumeCodecRejectsUnknownLegacyStep() {
        // Unknown LEGACY raw (v1 payload, no version field) → safe Welcome
        // through the migration map — never a crash, never a strand.
        let bad = Data(#"{"stepRaw":99,"skippedRaws":[],"practiceNote":""}"#.utf8)
        let decoded = OnboardingResumeCodec.decode(bad)
        #expect(decoded?.page == .welcome)
    }

    @Test func onboardingResumeCodecRejectsUnknownV2Page() {
        // Unknown v2 page raw → safe Welcome.
        let bad = Data(#"{"versionRaw":2,"pageRaw":99,"stepRaw":0,"skippedRaws":[],"practiceNote":""}"#.utf8)
        let decoded = OnboardingResumeCodec.decode(bad)
        #expect(decoded?.page == .welcome)
    }

    @Test func glassIntensityClamped() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        prefs.glassIntensity = 2
        #expect(prefs.glassIntensity == 1)
        prefs.glassIntensity = -1
        #expect(prefs.glassIntensity == 0)
    }

    @Test func holdToTalkStateTransitions() {
        var machine = HoldToTalkStateMachine(shortcut: .fn, monitoringEnabled: true)
        #expect(machine.handle(modifierMatchesShortcut: true, isKeyDown: true) == .beginHold)
        #expect(machine.phase == HoldToTalkPhase.holding)
        #expect(machine.handle(modifierMatchesShortcut: true, isKeyDown: true) == .ignore)
        #expect(machine.handle(modifierMatchesShortcut: false, isKeyDown: false) == .endHold)
        #expect(machine.phase == HoldToTalkPhase.idle)
    }

    @Test func holdToTalkDisabledIgnores() {
        var machine = HoldToTalkStateMachine(monitoringEnabled: false)
        #expect(machine.handle(modifierMatchesShortcut: true, isKeyDown: true) == .ignore)
    }

    @Test func holdToTalkMatcher() {
        #expect(HoldToTalkMatcher.matches(shortcut: .fn, fnDown: true, optionDown: false, commandDown: false, controlDown: false))
        #expect(!HoldToTalkMatcher.matches(shortcut: .fn, fnDown: false, optionDown: true, commandDown: false, controlDown: false))
        #expect(HoldToTalkMatcher.matches(shortcut: .option, fnDown: false, optionDown: true, commandDown: false, controlDown: false))
    }

    @Test func pkceChallengeAndStateValidation() {
        let pkce = OAuthPKCE.make()
        #expect(pkce.codeVerifier.count >= 43)
        #expect(pkce.validateCodeChallenge())
        #expect(pkce.validateReturnedState(pkce.state))
        #expect(!pkce.validateReturnedState("tampered"))
        #expect(!pkce.validateReturnedState(nil))
        #expect(OAuthPKCE.challengeS256(for: pkce.codeVerifier) == pkce.codeChallenge)
    }

    @Test func authorizationURLRequiresClientID() {
        let pkce = OAuthPKCE.make()
        #expect(OAuthAuthorizationURLBuilder.authorizationURL(clientID: "", redirectURI: "http://127.0.0.1/cb", pkce: pkce) == nil)
        let url = OAuthAuthorizationURLBuilder.authorizationURL(
            clientID: "desktop.apps.example",
            redirectURI: "http://127.0.0.1:53682/oauth/callback",
            pkce: pkce
        )
        #expect(url != nil)
        let q = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
        #expect(dict["response_type"] == "code")
        #expect(dict["code_challenge_method"] == "S256")
        #expect(dict["code_challenge"] == pkce.codeChallenge)
        #expect(dict["state"] == pkce.state)
        #expect(dict["scope"]?.contains("calendar.events") == true)
    }

    @Test func googleAuthPhaseUnconfigured() {
        let config = GoogleOAuthClientConfig(clientID: "")
        #expect(!config.isConfigured)
        #expect(
            GoogleAuthStateResolver.phase(
                config: config,
                hasLinkedAccounts: false,
                isAuthorizing: false,
                lastError: nil
            ) == .unconfigured
        )
    }

    @Test func googleAccountDirectoryRoundTrip() {
        let defaults = ephemeralDefaults()
        var directory = GoogleAccountDirectory()
        directory.upsert(GoogleLinkedAccount(id: "a1", email: "one@example.com", targetCalendarID: "primary"))
        GoogleAccountDirectoryStore.save(directory, to: defaults)
        let loaded = GoogleAccountDirectoryStore.load(from: defaults)
        #expect(loaded.accounts.count == 1)
        #expect(loaded.accounts[0].email == "one@example.com")
    }

    @Test func tokenVaultMockNoRealLogin() throws {
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(GoogleTokenBundle(refreshToken: "refresh-token-value"), accountID: "acc-1")
        #expect(try vault.loadTokenBundle(accountID: "acc-1")?.refreshToken == "refresh-token-value")
        try vault.deleteTokens(accountID: "acc-1")
        #expect(try vault.loadTokenBundle(accountID: "acc-1") == nil)
    }

    @Test func onboardingSessionNavigation() {
        var session = OnboardingSessionState()
        #expect(session.page == .welcome)
        #expect(!session.page.isSkippable)
        session.goNext()
        #expect(session.page == .calendar)
        session.skipCurrent()
        #expect(session.skipped.contains(.calendar))
        // 2026-11-07 owner correction: the dedicated Accessibility step
        // sits between Calendar and Voice setup in the walk order.
        #expect(session.page == .axPermission)
        session.goBack()
        #expect(session.page == .calendar)
        session.goNext()
        #expect(session.page == .axPermission)
        session.skipCurrent()
        #expect(session.skipped.contains(.axPermission))
        #expect(session.page == .voiceSetup)
        session.finish()
        #expect(session.completed)
        #expect(session.page == .ready)
        #expect(!OnboardingPage.ready.isSkippable)
    }

    @Test func practiceDraftNeverAllowsWrite() {
        #expect(!PracticeDraftPolicy.allowsCalendarWrite(isPracticeMode: true))
        #expect(PracticeDraftPolicy.allowsCalendarWrite(isPracticeMode: false))
        #expect(!PracticeDraftPolicy.practiceParseMayWriteToCalendar())
    }

    @Test func welcomeAndCompletionAreNotSkippable() {
        for step in OnboardingStep.allCases {
            if step == .welcome || step == .completion {
                #expect(!step.isSkippable)
            } else {
                #expect(step.isSkippable)
            }
        }
    }

    @Test func destinationPolicySingleLane() {
        #expect(
            DestinationPolicy.resolve(
                kind: .eventKit,
                eventKitCalendarID: "ek-1",
                googleAccountID: "g-1",
                googleCalendarID: "primary"
            ) == .eventKit(calendarID: "ek-1")
        )
        #expect(
            DestinationPolicy.resolve(
                kind: .google,
                eventKitCalendarID: "ek-1",
                googleAccountID: "g-1",
                googleCalendarID: "primary"
            ) == .google(accountID: "g-1", calendarID: "primary")
        )
        #expect(
            DestinationPolicy.resolve(
                kind: .google,
                eventKitCalendarID: "ek-1",
                googleAccountID: nil,
                googleCalendarID: nil
            ) == nil
        )
        #expect(!DestinationPolicy.canAttemptWrite(destination: nil, confirmationArmed: true))
        #expect(
            DestinationPolicy.canAttemptWrite(
                destination: .eventKit(calendarID: "ek"),
                confirmationArmed: true
            )
        )
    }

    @Test func tokenExchangeFormBodyContainsPKCE() {
        let body = OAuthTokenExchangeRequest.formBody(
            code: "auth-code",
            redirectURI: "http://127.0.0.1/cb",
            clientID: "client",
            codeVerifier: "verifier"
        )
        let s = String(data: body, encoding: .utf8) ?? ""
        #expect(s.contains("code_verifier=verifier"))
        #expect(s.contains("grant_type=authorization_code"))
        #expect(!s.contains("client_secret"))
    }
}
