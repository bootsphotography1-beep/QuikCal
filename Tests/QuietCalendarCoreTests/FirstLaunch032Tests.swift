import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.2: first-launch routing with isolated defaults, combined two-model
/// download honesty, and menu-bar coachmark geometry. No GUI, no network,
/// no real model weights — tiny mock fixtures only.
struct FirstLaunch032Tests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.firstlaunch032.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: First launch (isolated defaults)

    @Test func freshDefaultsColdStartOpensOnboarding() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        #expect(!prefs.onboardingCompleted)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: prefs.onboardingCompleted) == .onboarding)
    }

    @Test func incompleteResumeSurvivesProcessRestartAndRoutesOnboarding() {
        let defaults = ephemeralDefaults()
        var session = OnboardingSessionState(page: .voiceSetup, practiceNote: "keep me")
        session.skipped.insert(.calendar)
        AppPreferencesStore(defaults: defaults).saveOnboardingResume(session)
        // Simulate kill/restart: brand-new store over the same suite.
        let restarted = AppPreferencesStore(defaults: defaults)
        #expect(!restarted.onboardingCompleted)
        let resumed = restarted.makeOnboardingSession(forReplay: false)
        #expect(resumed.page == .voiceSetup)
        #expect(resumed.practiceNote == "keep me")
        #expect(resumed.skipped.contains(.calendar))
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: restarted.onboardingCompleted) == .onboarding)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: restarted.onboardingCompleted) == .onboarding)
    }

    @Test func completedSurvivesRestartColdStartMenuBarOnlyReopenConfigures() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.glassIntensity = 0.42
        prefs.selectedCalendarID = "cal-1"
        let restarted = AppPreferencesStore(defaults: defaults)
        #expect(restarted.onboardingCompleted)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true) == .menuBarOnly)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true) == .configuration)
        #expect(restarted.glassIntensity == 0.42)
        #expect(restarted.selectedCalendarID == "cal-1")
    }

    @Test func explicitReplayResetsOnlyOnboardingPreservesUserData() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.holdToTalkShortcut = .option
        prefs.selectedCalendarID = "keep"
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup))
        prefs.resetOnboardingCompletion()
        #expect(!prefs.onboardingCompleted)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.holdToTalkShortcut == .option)
        #expect(prefs.selectedCalendarID == "keep")
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false) == .onboarding)
    }

    @Test func coachmarkDismissalDoesNotResetOnboardingCompletion() {
        // Dismissal contract: only onboardingCompleted gates re-run; the hint
        // pref is separate (unit-level: reopen routing ignores a dismissed hint).
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.showMenuBarHint = true
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: prefs.onboardingCompleted) == .menuBarOnly)
        #expect(prefs.showMenuBarHint)
    }

    // MARK: Coachmark geometry (pure, no display)

    @Test func coachmarkAnchorsRealTargetWithNegativeOrigin() {
        // Secondary monitor at negative origin (left of primary).
        let visible = ScreenRect(x: -1920, y: 0, width: 1920, height: 1040)
        let target = ScreenRect(x: -220, y: 1010, width: 60, height: 24)
        let layout = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: target,
            visibleFrame: visible,
            cardSize: ScreenSize(width: 320, height: 190)
        )
        #expect(layout.isAnchored)
        // Ring hugs the real target (expanded 8pt, inside visible frame).
        #expect(layout.ringRect?.x == -228)
        #expect((layout.ringRect?.x ?? 0) <= -190 && -190 <= (layout.ringRect?.maxX ?? 0))
        // Card below the ring, clamped inside the visible frame.
        #expect(layout.cardOrigin.y + 190 <= 1034)
        #expect(layout.cardOrigin.x >= -1920)
        #expect(layout.cardOrigin.x + 320 <= 0)
    }

    @Test func coachmarkFallbackHiddenOrZeroTarget() {
        let visible = ScreenRect(x: 0, y: 0, width: 1512, height: 950)
        let nilTarget = MenuBarCoachmarkGeometry.layout(targetScreenFrame: nil, visibleFrame: visible, cardSize: ScreenSize(width: 320, height: 190))
        #expect(!nilTarget.isAnchored)
        #expect(nilTarget.ringRect == nil)
        // Fallback card stays inside the visible frame (never offscreen).
        #expect(nilTarget.cardOrigin.y >= 0)
        #expect(nilTarget.cardOrigin.y + nilTarget.cardSize.height <= visible.maxY)
        let zero = MenuBarCoachmarkGeometry.layout(targetScreenFrame: ScreenRect(x: 0, y: 0, width: 0, height: 0), visibleFrame: visible, cardSize: ScreenSize(width: 320, height: 190))
        #expect(!zero.isAnchored)
    }

    @Test func coachmarkFallbackOffscreenTarget() {
        let visible = ScreenRect(x: 0, y: 0, width: 1512, height: 950)
        // Target entirely outside visible frame (e.g. menu bar hidden by fullscreen app).
        let offscreen = ScreenRect(x: 5000, y: 5000, width: 60, height: 24)
        let layout = MenuBarCoachmarkGeometry.layout(targetScreenFrame: offscreen, visibleFrame: visible, cardSize: ScreenSize(width: 320, height: 190))
        #expect(!layout.isAnchored)
        #expect(layout.cardOrigin.x + layout.cardSize.width <= visible.maxX)
        #expect(layout.cardOrigin.x >= visible.x)
    }

    @Test func coachmarkAboveFallbackWhenNoRoomBelow() {
        let visible = ScreenRect(x: 0, y: 0, width: 1512, height: 300)
        let target = ScreenRect(x: 700, y: 10, width: 60, height: 24)
        let layout = MenuBarCoachmarkGeometry.layout(targetScreenFrame: target, visibleFrame: visible, cardSize: ScreenSize(width: 320, height: 190))
        #expect(layout.isAnchored)
        // No room below → card above the ring, still clamped inside visible frame.
        #expect(layout.cardOrigin.y >= target.maxY)
        #expect(layout.cardOrigin.y + 190 <= visible.maxY)
    }
}
