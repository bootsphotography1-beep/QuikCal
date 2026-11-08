import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.8: onboarding persistence lifecycle, cross-page download banner
/// policy, activation recheck policy, and banner motion spec. Pure logic
/// only — no GUI, no network, no real weights, no TCC/permission changes.
///
/// 2026-11-07 compact 4-page update: the step-contract tests were retired
/// with replacement PAGE coverage (the genuine safety behaviors — durable
/// resume, honest skips, completion gating — are all preserved and still
/// asserted); the legacy→page migration itself is covered by
/// OnboardingCompact4PageMigrationTests.
struct OnboardingPersistenceMotion038Tests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.onboarding038.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Cross-page download banner policy

    /// A download started on the Voice setup page keeps running while the
    /// user is on any other page — the banner is the persistent progress
    /// surface.
    @Test func bannerVisibleDuringTransferOnEveryNonVoiceSetupPage() {
        for page in OnboardingPage.allCases where page != .voiceSetup {
            #expect(OnboardingDownloadBannerPolicy.isVisible(
                currentPage: page,
                isTransferring: true,
                speechPhase: .downloading
            ))
        }
    }

    @Test func bannerHiddenOnVoiceSetupPagePanelOwnsProgress() {
        #expect(!OnboardingDownloadBannerPolicy.isVisible(
            currentPage: .voiceSetup,
            isTransferring: true,
            speechPhase: .downloading
        ))
    }

    @Test func bannerHiddenWhenIdleAndReady() {
        #expect(!OnboardingDownloadBannerPolicy.isVisible(
            currentPage: .voiceSetup,
            isTransferring: false,
            speechPhase: .ready
        ))
        #expect(!OnboardingDownloadBannerPolicy.isVisible(
            currentPage: .welcome,
            isTransferring: false,
            speechPhase: .idle
        ))
    }

    /// Honest aftermath: a failed or cancelled transfer stays visible as a
    /// retry surface even though nothing is transferring any more.
    @Test func bannerVisibleAfterFailureOrCancelNotOnlyWhileTransferring() {
        for phase in [ParakeetDownloadPhase.failed, .cancelled] {
            #expect(OnboardingDownloadBannerPolicy.isVisible(
                currentPage: .calendar,
                isTransferring: false,
                speechPhase: phase
            ))
            #expect(OnboardingDownloadBannerPolicy.isVisible(
                currentPage: .ready,
                isTransferring: false,
                speechPhase: phase
            ))
        }
    }

    @Test func bannerNeverFakesProgressFromVerifiedDiskWeights() {
        // Ready-on-disk from a previous setup must not summon the banner.
        #expect(!OnboardingDownloadBannerPolicy.isVisible(
            currentPage: .calendar,
            isTransferring: false,
            speechPhase: .ready
        ))
    }

    // MARK: - Activation recheck policy (honest grant detection)

    @Test func activationRecheckCoversCalendarAccessibilityAndVoiceSetupPages() {
        #expect(OnboardingActivationRecheckPolicy.shouldRecheck(page: .calendar))
        // 2026-11-07 owner correction: the dedicated Accessibility step
        // re-probes on activation too (returning from System Settings).
        #expect(OnboardingActivationRecheckPolicy.shouldRecheck(page: .axPermission))
        #expect(OnboardingActivationRecheckPolicy.shouldRecheck(page: .voiceSetup))
    }

    @Test func activationRecheckSkipsNonPermissionPages() {
        for page in [OnboardingPage.welcome, OnboardingPage.ready] {
            #expect(!OnboardingActivationRecheckPolicy.shouldRecheck(page: page))
        }
    }

    // MARK: - Banner motion (Reduce Motion contract)

    @Test func bannerMotionReduceMotionIsShortFadeOnly() {
        let spec = OnboardingBannerMotionSpec.spec(reduceMotion: true)
        #expect(spec.fadeOnly)
        #expect(spec.insertionOffsetPoints == 0)
        #expect(spec.durationSeconds <= 0.15)
    }

    @Test func bannerMotionNormalIsSubtleRiseFade() {
        let spec = OnboardingBannerMotionSpec.spec(reduceMotion: false)
        #expect(!spec.fadeOnly)
        #expect(spec.insertionOffsetPoints > 0)
        #expect(spec.insertionOffsetPoints <= 12)
        #expect(spec.durationSeconds <= 0.3)
    }

    // MARK: - Persistence lifecycle (durable resume across relaunch)

    @Test func everyPageRoundTripsAcrossRestart() {
        for page in OnboardingPage.allCases {
            let defaults = ephemeralDefaults()
            var session = OnboardingSessionState(page: page)
            if page.isSkippable { session.skipped.insert(page) }
            AppPreferencesStore(defaults: defaults).saveOnboardingResume(session)
            // Simulated relaunch: brand-new store over the same domain.
            let restarted = AppPreferencesStore(defaults: defaults)
            let resumed = restarted.makeOnboardingSession(forReplay: false)
            #expect(resumed.page == page)
            if page.isSkippable {
                #expect(resumed.skipped.contains(page))
            }
        }
    }

    /// Mid-permission-flow resume: a user killed mid “Open System Settings”
    /// (or recheck) comes back to the merged Voice setup page with the
    /// guide's exact phase and the honest recheck status they had — never
    /// silently advanced or reset. The shortcut is not carried in the
    /// snapshot; it is durable separately in prefs and the view re-syncs
    /// it on appear (single source of truth).
    @Test func holdGuideMidPhaseAndRecheckStatusSurviveRestart() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.holdToTalkShortcut = .option
        var guide = HoldToTalkGuideState(shortcut: .option)
        guide.phase = .openSettings
        guide.applyAccessibilityTrusted(false)
        let session = OnboardingSessionState(page: .voiceSetup, holdGuide: guide)
        prefs.saveOnboardingResume(session)
        // Simulated relaunch: brand-new store + fresh session like the view.
        let restarted = AppPreferencesStore(defaults: defaults)
        var resumed = restarted.makeOnboardingSession(forReplay: false)
        resumed.holdGuide.shortcut = restarted.holdToTalkShortcut
        #expect(restarted.holdToTalkShortcut == .option)
        #expect(resumed.page == .voiceSetup)
        #expect(resumed.holdGuide.phase == .openSettings)
        #expect(resumed.holdGuide.shortcut == .option)
        #expect(resumed.holdGuide.accessibilityRecheck == .denied)
    }

    @Test func practiceNoteSurvivesRestart() {
        let defaults = ephemeralDefaults()
        AppPreferencesStore(defaults: defaults).saveOnboardingResume(
            OnboardingSessionState(page: .voiceSetup, practiceNote: "Lunch with Ana Friday noon")
        )
        let resumed = AppPreferencesStore(defaults: defaults).makeOnboardingSession(forReplay: false)
        #expect(resumed.practiceNote == "Lunch with Ana Friday noon")
    }

    /// Finish is the only silent-clear path: completion persists, the resume
    /// cursor is gone, and a relaunch routes to menu bar / configuration —
    /// never back into onboarding.
    @Test func finishClearsCursorAndCompletionPersistsAcrossRestart() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        var session = OnboardingSessionState(page: .ready)
        session.finish()
        prefs.onboardingCompleted = true
        prefs.saveOnboardingResume(session) // completed → cursor cleared
        let restarted = AppPreferencesStore(defaults: defaults)
        #expect(restarted.onboardingCompleted)
        #expect(restarted.onboardingResume == nil)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: restarted.onboardingCompleted) == .menuBarOnly)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: restarted.onboardingCompleted) == .configuration)
    }

    /// “Explicit appropriate skip” gate: skipping records the page in the
    /// skipped set and advances — it never fabricates completion, and a
    /// mid-journey skip still resumes (not finished) after relaunch.
    /// 2026-11-07 owner correction: skipping Calendar now advances to the
    /// dedicated Accessibility step (the step before voice practice).
    @Test func explicitSkipIsRecordedAndResumeStaysIncomplete() {
        let defaults = ephemeralDefaults()
        var session = OnboardingSessionState(page: .calendar)
        session.skipCurrent()
        #expect(session.skipped.contains(.calendar))
        #expect(!session.completed)
        #expect(session.page == .axPermission)
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.saveOnboardingResume(session)
        let restarted = AppPreferencesStore(defaults: defaults)
        #expect(!restarted.onboardingCompleted)
        let resumed = restarted.makeOnboardingSession(forReplay: false)
        #expect(resumed.page == .axPermission)
        #expect(resumed.skipped.contains(.calendar))
    }

    @Test func staleResumeClearedOnlyWhenCompleted() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup))
        // Incomplete journey: cursor untouched.
        #expect(!prefs.clearStaleResumeIfCompleted())
        #expect(prefs.onboardingResume != nil)
        // Completed + leftover cursor: only the cursor is cleared.
        prefs.onboardingCompleted = true
        prefs.saveOnboardingResume(OnboardingSessionState(page: .welcome))
        #expect(prefs.onboardingResume != nil) // saveOnboardingResume cleared it on completed session
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup, completed: false))
        // Force the stale shape: completed flag + a cursor.
        prefs.onboardingResume = OnboardingResumeSnapshot(page: .voiceSetup)
        #expect(prefs.clearStaleResumeIfCompleted())
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.onboardingCompleted)
    }

    /// Replay is the only intentional reset: fresh journey, cursor gone, and
    /// unrelated prefs untouched (calendar selection preserved here).
    @Test func replayResetsJourneyOnly() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.selectedCalendarID = "keep-me"
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup))
        let replayed = prefs.makeOnboardingSession(forReplay: true)
        #expect(replayed.page == .welcome)
        #expect(!replayed.completed)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.selectedCalendarID == "keep-me")
    }
}
