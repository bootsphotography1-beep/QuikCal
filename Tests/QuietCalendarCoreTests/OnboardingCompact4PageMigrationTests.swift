import Testing
import Foundation
@testable import QuietCalendarCore

/// P3 compact 4-page onboarding migration (2026-11-07). The MANDATORY
/// explicit legacy→page map, versioned snapshots, and completed-profile
/// pins. No reset of any existing state is ever performed by migration.
struct OnboardingCompact4PageMigrationTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.onboarding4page.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - The explicit map (every legacy raw → exactly one page)

    /// MANDATORY map: 0 welcome→welcome, 1 appearance→welcome,
    /// 2 calendarConnection→calendar, 3 speechPrivacy→voiceSetup,
    /// 4 holdToTalk→voiceSetup, 5 practiceDraft→voiceSetup,
    /// 6 completion→ready. Unknown raw → safe Welcome.
    @Test func everyLegacyStepRawMapsToExactlyOnePage() {
        let expected: [Int: OnboardingPage] = [
            0: .welcome,
            1: .welcome,
            2: .calendar,
            3: .voiceSetup,
            4: .voiceSetup,
            5: .voiceSetup,
            6: .ready
        ]
        for (raw, page) in expected {
            #expect(OnboardingPageMigration.page(forLegacyStepRaw: raw) == page)
        }
        // Every legacy raw (including unknowns) lands on a valid page.
        for raw in -2...99 {
            _ = OnboardingPageMigration.page(forLegacyStepRaw: raw)
        }
    }

    @Test func unknownLegacyRawLandsOnWelcome() {
        #expect(OnboardingPageMigration.page(forLegacyStepRaw: 99) == .welcome)
        #expect(OnboardingPageMigration.page(forLegacyStepRaw: -1) == .welcome)
        #expect(OnboardingPageMigration.page(forLegacyStepRaw: 7) == .welcome)
    }

    @Test func legacySkippedStepsCollapseToPages() {
        let pages = OnboardingPageMigration.skippedPages(forLegacySkippedRaws: [1, 3, 4, 5])
        // appearance skip collapses into the welcome page skip; the three
        // merged voice pages collapse into ONE voiceSetup skip.
        #expect(pages == [.welcome, .voiceSetup])
    }

    // MARK: - Versioned snapshot decode (legacy payloads migrate)

    /// A REAL legacy persisted payload (v1, no version field) decodes onto
    /// the correct page through the map — no reset, no strand.
    @Test func legacySnapshotPayloadDecodesThroughTheMap() {
        // Raw JSON exactly as a 0.3.x install would have persisted it.
        let legacy: [Int: OnboardingPage] = [
            0: .welcome, 1: .welcome, 2: .calendar,
            3: .voiceSetup, 4: .voiceSetup, 5: .voiceSetup, 6: .ready
        ]
        for (raw, page) in legacy {
            let json = #"{"stepRaw":\#(raw),"skippedRaws":[],"practiceNote":"keep"}"#
            let data = Data(json.utf8)
            let decoded = OnboardingResumeCodec.decode(data)
            #expect(decoded?.page == page, "legacy raw \(raw)")
            #expect(decoded?.practiceNote == "keep")
        }
    }

    @Test func legacySnapshotWithSkipsDecodesSkippedPages() {
        let json = #"{"stepRaw":4,"skippedRaws":[1,2],"practiceNote":""}"#
        let decoded = OnboardingResumeCodec.decode(Data(json.utf8))
        #expect(decoded?.page == .voiceSetup)
        #expect(decoded?.skipped == [.welcome, .calendar])
    }

    @Test func v2SnapshotRoundTripsEveryPage() {
        for page in OnboardingPage.allCases {
            let snapshot = OnboardingResumeSnapshot(page: page, skipped: [page])
            let data = OnboardingResumeCodec.encode(snapshot)
            let decoded = OnboardingResumeCodec.decode(data)
            #expect(decoded?.page == page)
            #expect(decoded?.skipped == [page])
            #expect(decoded?.versionRaw == OnboardingFlowVersion.compactFourPage.rawValue)
        }
    }

    @Test func v2SnapshotWithCorruptPageRawLandsOnWelcome() {
        let json = #"{"versionRaw":2,"pageRaw":42,"stepRaw":2,"skippedRaws":[],"practiceNote":""}"#
        let decoded = OnboardingResumeCodec.decode(Data(json.utf8))
        #expect(decoded?.page == .welcome)
    }

    // MARK: - Legacy raw values are FROZEN (never renumbered/repurposed)

    @Test func legacyStepRawValuesNeverChange() {
        #expect(OnboardingStep.welcome.rawValue == 0)
        #expect(OnboardingStep.appearance.rawValue == 1)
        #expect(OnboardingStep.calendarConnection.rawValue == 2)
        #expect(OnboardingStep.speechPrivacy.rawValue == 3)
        #expect(OnboardingStep.holdToTalk.rawValue == 4)
        #expect(OnboardingStep.practiceDraft.rawValue == 5)
        #expect(OnboardingStep.completion.rawValue == 6)
    }

    @Test func pageRawValuesAreStable() {
        #expect(OnboardingPage.welcome.rawValue == 0)
        #expect(OnboardingPage.calendar.rawValue == 1)
        #expect(OnboardingPage.voiceSetup.rawValue == 2)
        #expect(OnboardingPage.ready.rawValue == 3)
        // 2026-11-07 owner correction: the dedicated Accessibility step
        // takes raw 4 — existing raws 0–3 are frozen (no renumbering).
        #expect(OnboardingPage.axPermission.rawValue == 4)
        #expect(OnboardingPage.allCases.count == 5)
    }

    // MARK: - Completed profiles never see the flow again

    @Test func completedProfileIsNeverBlockedByMigration() {
        // The completion gate is independent of the map: a completed user's
        // leftover cursor is cleared, routing stays menu-bar/config.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        // Even a stale legacy cursor at ANY step does not re-open flow.
        for raw in 0...6 {
            let legacyJSON = "{\"stepRaw\":\(raw),\"skippedRaws\":[],\"practiceNote\":\"x\"}"
            prefs.onboardingResume = OnboardingResumeCodec.decode(Data(legacyJSON.utf8))
            #expect(prefs.onboardingResume != nil)
            #expect(prefs.clearStaleResumeIfCompleted())
            #expect(prefs.onboardingResume == nil)
            #expect(prefs.onboardingCompleted)
            #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true) == .menuBarOnly)
            #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true) == .configuration)
        }
    }

    @Test func incompleteLegacyCursorResumesOnMigratedPage() {
        // Incomplete journey mid-hold-guide (step 4) resumes on the merged
        // Voice setup page with the guide state intact — no forced replay.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        // Raw JSON exactly as a 0.3.x install would have persisted it
        // (step 4 = holdToTalk, guide mid openSettings, recheck denied).
        let legacyJSON = #"{"stepRaw":4,"skippedRaws":[],"practiceNote":"","holdGuidePhaseRaw":3,"accessibilityRecheckRaw":"denied"}"#
        prefs.onboardingResume = OnboardingResumeCodec.decode(Data(legacyJSON.utf8))
        #expect(prefs.onboardingResume != nil)
        let resumed = prefs.makeOnboardingSession(forReplay: false)
        #expect(resumed.page == .voiceSetup)
        #expect(resumed.holdGuide.phase == .openSettings)
        #expect(resumed.holdGuide.accessibilityRecheck == .denied)
    }

    // MARK: - Page model contracts

    @Test func welcomeAndReadyAreAnchors() {
        #expect(!OnboardingPage.welcome.isSkippable)
        #expect(!OnboardingPage.ready.isSkippable)
        #expect(OnboardingPage.calendar.isSkippable)
        #expect(OnboardingPage.voiceSetup.isSkippable)
        // The dedicated Accessibility step is skippable (typing always
        // works) — but it IS its own step before voice practice.
        #expect(OnboardingPage.axPermission.isSkippable)
    }

    /// 2026-11-07 owner correction: the dedicated Accessibility
    /// verification step sits BETWEEN Calendar and Voice setup — before
    /// any voice practice. The flow order is explicit (`flowOrder`), not
    /// raw arithmetic (axPermission = 4 walks before voiceSetup = 2).
    @Test func pageFlowOrderIsWelcomeCalendarAccessibilityVoiceSetupReady() {
        #expect(OnboardingPage.flowOrder == [.welcome, .calendar, .axPermission, .voiceSetup, .ready])
        #expect(OnboardingPage.welcome.next == .calendar)
        #expect(OnboardingPage.calendar.next == .axPermission)
        #expect(OnboardingPage.axPermission.next == .voiceSetup)
        #expect(OnboardingPage.voiceSetup.next == .ready)
        #expect(OnboardingPage.ready.next == nil)
        #expect(OnboardingPage.ready.previous == .voiceSetup)
        #expect(OnboardingPage.voiceSetup.previous == .axPermission)
        #expect(OnboardingPage.axPermission.previous == .calendar)
        // Comparable follows the WALK order, not raw values.
        #expect(OnboardingPage.axPermission < OnboardingPage.voiceSetup)
        #expect(OnboardingPage.calendar < OnboardingPage.axPermission)
        #expect(OnboardingPage.axPermission.flowIndex == 2)
    }

    // MARK: - Connections/models/prefs survive migration untouched

    @Test func migrationNeverTouchesConnectionsModelsOrPrefs() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = false
        prefs.selectedCalendarID = "my-calendar"
        prefs.glassIntensity = 0.7
        prefs.holdToTalkShortcut = .command
        prefs.calendarDestinationKind = .google
        // Simulate an old install's legacy cursor (raw v1 payload, step 3).
        let legacyJSON = #"{"stepRaw":3,"skippedRaws":[],"practiceNote":""}"#
        prefs.onboardingResume = OnboardingResumeCodec.decode(Data(legacyJSON.utf8))
        #expect(prefs.onboardingResume != nil)
        // The ONLY thing migration does: decode the cursor onto the new
        // page model. Every other pref is untouched.
        let resumed = prefs.makeOnboardingSession(forReplay: false)
        #expect(resumed.page == .voiceSetup)
        #expect(prefs.selectedCalendarID == "my-calendar")
        #expect(prefs.glassIntensity == 0.7)
        #expect(prefs.holdToTalkShortcut == .command)
        #expect(prefs.calendarDestinationKind == .google)
        #expect(prefs.onboardingCompleted == false)
    }

    // MARK: - Pending replay-once question is NOT forced

    @Test func replayIsOnlyEverExplicit() {
        // makeOnboardingSession(forReplay: true) is the ONLY fresh-journey
        // path; a restored cursor never forces a replay.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingResume = OnboardingResumeSnapshot(page: .calendar)
        let resumed = prefs.makeOnboardingSession(forReplay: false)
        #expect(resumed.page == .calendar)
        let replay = prefs.makeOnboardingSession(forReplay: true)
        #expect(replay.page == .welcome)
    }
}
