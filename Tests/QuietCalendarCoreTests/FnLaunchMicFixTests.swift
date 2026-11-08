import Testing
import Foundation
@testable import QuietCalendarCore

/// FN-LAUNCH-MIC-FIX (0.3.11): persisted hold-to-talk intent + launch
/// restore + first-hold mic request flow. Pure policies and preference
/// migration only — no TCC, no live mic, no AppKit monitors here.
struct FnLaunchMicFixTests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - One-time migration of the enabled intent

    @Test func migrationInfersEnabledOnlyFromCompletedShortcutSetup() {
        // Actual prior settings: onboarding finished AND the shortcut key
        // was explicitly written by the hold guide → infer enabled.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        defaults.set(HoldToTalkShortcutKind.fn.rawValue, forKey: AppPreferenceKey.holdToTalkShortcut)
        #expect(prefs.holdToTalkMonitoringEnabled == true)
        // Persisted once — becomes the durable explicit choice.
        #expect(prefs.holdToTalkEnabledExplicit == true)
    }

    @Test func migrationInheritsOffWhenShortcutKeyNeverWritten() {
        // User completed onboarding but skipped the hold guide (skipping
        // never writes the shortcut key) → inherits off, same as every
        // relaunch before this fix. No silent override.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        #expect(prefs.holdToTalkMonitoringEnabled == false)
        #expect(prefs.holdToTalkEnabledExplicit == false)
    }

    @Test func migrationInheritsOffWhenOnboardingIncomplete() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        defaults.set(HoldToTalkShortcutKind.option.rawValue, forKey: AppPreferenceKey.holdToTalkShortcut)
        #expect(prefs.holdToTalkMonitoringEnabled == false)
        #expect(prefs.holdToTalkEnabledExplicit == false)
    }

    @Test func explicitChoiceIsNeverOverriddenByMigration() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        defaults.set(HoldToTalkShortcutKind.fn.rawValue, forKey: AppPreferenceKey.holdToTalkShortcut)

        // Explicitly disabled wins even though setup looks completed.
        defaults.set(false, forKey: AppPreferenceKey.holdToTalkEnabled)
        #expect(prefs.holdToTalkMonitoringEnabled == false)
        #expect(prefs.holdToTalkEnabledExplicit == false)

        // Explicitly enabled wins even when migration would say otherwise.
        defaults.set(true, forKey: AppPreferenceKey.holdToTalkEnabled)
        #expect(prefs.holdToTalkMonitoringEnabled == true)
    }

    @Test func migrationRunsOnceAndLaterCompletionDoesNotFlipIt() {
        // Fresh user skips the guide → migration persists false. Completing
        // onboarding later must NOT retro-flip the persisted choice; only an
        // explicit enable does.
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        #expect(prefs.holdToTalkMonitoringEnabled == false)
        prefs.onboardingCompleted = true
        defaults.set(HoldToTalkShortcutKind.fn.rawValue, forKey: AppPreferenceKey.holdToTalkShortcut)
        #expect(prefs.holdToTalkMonitoringEnabled == false)
        // Explicit enable flips it durably.
        prefs.holdToTalkMonitoringEnabled = true
        #expect(prefs.holdToTalkMonitoringEnabled == true)
        // Explicit disable flips it durably.
        prefs.holdToTalkMonitoringEnabled = false
        #expect(prefs.holdToTalkMonitoringEnabled == false)
    }

    // MARK: - Launch / activation restore decision

    @Test func restoreOnlyWithEnabledIntentRealTrustAndNotInstalled() {
        // The core fix: enabled intent + REAL Accessibility trust → restore.
        #expect(HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: true, monitoringInstalled: false))
        // Intentionally disabled choice never auto-starts.
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: false, requiredCapabilityGranted: true, monitoringInstalled: false))
        // Unknown intent (pre-migration fresh user) never auto-starts.
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: nil, requiredCapabilityGranted: true, monitoringInstalled: false))
        // A pref NEVER fakes trust: untrusted → no restore.
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: false, monitoringInstalled: false))
        // Already installed → nothing to restore.
        #expect(!HoldToTalkLaunchPolicy.shouldAttemptRestore(
            enabledIntent: true, requiredCapabilityGranted: true, monitoringInstalled: true))
    }

    // MARK: - Mic grant continuation (no auto recordings)

    @Test func grantContinuesOnlyStillActiveSafeHold() {
        // Key still physically held (phase + live HID state agree) + state
        // safe → the current hold records.
        #expect(HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: true, keyPhysicallyDown: true, screenSafeForCapture: true, speechIdle: true))
        // Physical key released before the grant → next hold records.
        #expect(!HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: false, keyPhysicallyDown: true, screenSafeForCapture: true, speechIdle: true))
        // STALE GLOBAL MODIFIER STATE: monitor-derived phase still says
        // "holding" (release event swallowed while the system mic prompt had
        // key focus) but the LIVE physical key is up → never records.
        #expect(!HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: true, keyPhysicallyDown: false, screenSafeForCapture: true, speechIdle: true))
        // Confirmation screen open / speech busy → state not safe → next hold.
        #expect(!HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: true, keyPhysicallyDown: true, screenSafeForCapture: false, speechIdle: true))
        #expect(!HoldToTalkLaunchPolicy.shouldContinueHoldAfterMicGrant(
            holdStillActive: true, keyPhysicallyDown: true, screenSafeForCapture: true, speechIdle: false))
    }
}
