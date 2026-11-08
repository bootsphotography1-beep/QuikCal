import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.6: draggable Accessibility guide payload/copy, stale-resume launch
/// cleanup, and once-per-presentation pop policy. No GUI, no TCC, no DMG.
@Suite("Accessibility Drag Onboarding 036")
struct AccessibilityDragOnboarding036Tests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.drag036.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Drag payload identity

    @Test func payloadExportsOnlyExpectedBundleAppFile() {
        let payload = AccessibilityDragPayload(
            bundlePath: "/Applications/QuikCal.app",
            bundleID: "com.quietcalendar.app"
        )
        #expect(payload.isValidExport)
        #expect(payload.fileURL.pathExtension == "app")
        #expect(payload.pasteboardType == "public.file-url")
        #expect(payload.location == .installedApplications)
        #expect(payload.offersDragTile)

        let wrongID = AccessibilityDragPayload(
            bundlePath: "/Applications/QuikCal.app", bundleID: "com.example.other")
        #expect(!wrongID.isValidExport)
        #expect(!wrongID.offersDragTile)

        let notAnApp = AccessibilityDragPayload(
            bundlePath: "/Applications/QuietCalendar", bundleID: "com.quietcalendar.app")
        #expect(!notAnApp.isValidExport)
    }

    @Test func locationClassificationAndInstallFirst() {
        #expect(AccessibilityAppLocation.classify(bundlePath: "/Applications/QuikCal.app") == .installedApplications)
        #expect(AccessibilityAppLocation.classify(bundlePath: "/Volumes/QuikCal 0.3.6/QuikCal.app") == .mountedDiskImage)
        #expect(AccessibilityAppLocation.classify(bundlePath: "/private/var/folders/x/AppTranslocation/UUID/QuikCal.app") == .appTranslocation)
        #expect(AccessibilityAppLocation.classify(bundlePath: "/Users/example/project/build/QuikCal.app") == .developerBuild)
        #expect(AccessibilityAppLocation.classify(bundlePath: "/Users/example/project/build/qa-036/QuikCal.app") == .developerBuild)
        #expect(AccessibilityAppLocation.mountedDiskImage.requiresInstallFirst)
        #expect(AccessibilityAppLocation.appTranslocation.requiresInstallFirst)
        #expect(!AccessibilityAppLocation.installedApplications.requiresInstallFirst)
        #expect(!AccessibilityAppLocation.developerBuild.requiresInstallFirst)

        // Mounted/translocated valid exports must NOT offer a drag tile.
        for path in ["/Volumes/QuikCal 0.3.6/QuikCal.app",
                     "/private/var/folders/x/AppTranslocation/UUID/QuikCal.app"] {
            let p = AccessibilityDragPayload(bundlePath: path, bundleID: "com.quietcalendar.app")
            #expect(p.isValidExport)
            #expect(!p.offersDragTile)
        }
        let dev = AccessibilityDragPayload(
            bundlePath: "/Users/example/project/build/QuikCal.app", bundleID: "com.quietcalendar.app")
        #expect(dev.isDeveloperBuildCopy)
        #expect(dev.offersDragTile)
    }

    // MARK: Copy honesty

    @Test func dragCopyIsConditionalAndNeverClaimsGrantOrMembership() {
        #expect(AccessibilityDragGuideCopy.steps.count == 3)
        #expect(AccessibilityDragGuideCopy.steps[1].contains("Drag QuikCal"))
        #expect(AccessibilityDragGuideCopy.steps[1].contains("missing"))
        #expect(AccessibilityDragGuideCopy.alreadyListedHint.contains("Already listed"))
        #expect(AccessibilityDragGuideCopy.approveNote.contains("approve this in System Settings"))
        #expect(AccessibilityDragGuideCopy.dragDoesNotGrant.contains("does not turn on Accessibility"))
        #expect(AccessibilityDragGuideCopy.tileAccessibilityLabel.contains("Drag"))
        #expect(AccessibilityDragGuideCopy.tileAccessibilityLabel.contains("does not turn on Accessibility"))
        // No claim that we know list membership from AXIsProcessTrusted.
        #expect(AccessibilityDragGuideCopy.detailsMembership.contains("can’t see"))
        #expect(AccessibilityDragGuideCopy.detailsAuthentication.contains("authenticate"))
        // Mic/Calendar are normal prompts, Input Monitoring is not an AX alternative.
        #expect(AccessibilityDragGuideCopy.detailsMicCalendar.contains("normal prompts"))
        #expect(AccessibilityDragGuideCopy.detailsInputMonitoring.contains("required for the Fn shortcut"))
    }

    @Test func trustedShowsEnabledUntrustedStaysConditional() {
        #expect(AccessibilityDragGuideCopy.statusLine(accessibilityTrusted: true, location: .installedApplications)
            == AccessibilityDragGuideCopy.trustedNextStep)
        #expect(AccessibilityDragGuideCopy.statusLine(accessibilityTrusted: false, location: .installedApplications)
            == AccessibilityDragGuideCopy.manualNextNote)
        #expect(AccessibilityDragGuideCopy.statusLine(accessibilityTrusted: false, location: .mountedDiskImage)
            == AccessibilityDragGuideCopy.installFirstBody)
        #expect(AccessibilityDragGuideCopy.enabledCheck == "Enabled")
        #expect(AccessibilityDragGuideCopy.checkAgain == "Check again")
    }

    // MARK: Pop animation policy

    @Test func popSpecSpringNormalFadeOnlyReduceMotion() {
        let normal = OnboardingPopAnimationSpec.spec(reduceMotion: false)
        #expect(normal.initialScale == 0.94)
        #expect(normal.finalScale == 1.0)
        #expect(normal.durationSeconds >= 0.24 && normal.durationSeconds <= 0.30)
        #expect(!normal.fadeOnly)
        #expect(normal.gentleOvershoot)

        let reduced = OnboardingPopAnimationSpec.spec(reduceMotion: true)
        #expect(reduced.initialScale == 1.0)
        #expect(reduced.finalScale == 1.0)
        #expect(reduced.durationSeconds >= 0.10 && reduced.durationSeconds <= 0.15)
        #expect(reduced.fadeOnly)
        #expect(!reduced.gentleOvershoot)
    }

    @Test func presentationIdentityStableAcrossUpdatesNewOnlyOnNewPresentation() {
        var tracker = OnboardingPresentationTracker()
        let first = tracker.presentationID
        // Download / focus / step updates reuse the identity (no re-pop).
        #expect(tracker.refreshedWithoutReanimating() == first)
        #expect(tracker.presentationID == first)
        // Manual Replay / fresh open is a new presentation.
        let second = tracker.newPresentation()
        #expect(second != first)
        #expect(tracker.presentationID == second)
    }

    // MARK: Launch / stale resume

    @Test func freshIncompleteOpensOnboarding() {
        let prefs = AppPreferencesStore(defaults: ephemeralDefaults())
        #expect(!prefs.onboardingCompleted)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: prefs.onboardingCompleted) == .onboarding)
    }

    @Test func completeWithStaleResumeClearsOnlyResume() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.glassIntensity = 0.42
        prefs.selectedCalendarID = "keep"
        prefs.holdToTalkShortcut = .option
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup))
        #expect(prefs.onboardingResume != nil)
        #expect(prefs.clearStaleResumeIfCompleted())
        #expect(prefs.onboardingResume == nil)
        // Everything else untouched.
        #expect(prefs.onboardingCompleted)
        #expect(prefs.glassIntensity == 0.42)
        #expect(prefs.selectedCalendarID == "keep")
        #expect(prefs.holdToTalkShortcut == .option)
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: true) == .menuBarOnly)
        #expect(AppLaunchRouter.surface(trigger: .applicationReopen, onboardingCompleted: true) == .configuration)
    }

    @Test func incompleteCursorIsNotStaleAndRestores() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.saveOnboardingResume(OnboardingSessionState(page: .voiceSetup, practiceNote: "keep me"))
        #expect(!prefs.clearStaleResumeIfCompleted())
        #expect(prefs.onboardingResume?.page == .voiceSetup)
        #expect(prefs.makeOnboardingSession(forReplay: false).practiceNote == "keep me")
    }

    @Test func completedWithoutResumeIsNoOpAndReplayResetsOnlyOnboarding() {
        let defaults = ephemeralDefaults()
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.onboardingCompleted = true
        prefs.selectedCalendarID = "keep"
        #expect(!prefs.clearStaleResumeIfCompleted())
        prefs.resetOnboardingCompletion()
        #expect(!prefs.onboardingCompleted)
        #expect(prefs.onboardingResume == nil)
        #expect(prefs.selectedCalendarID == "keep")
        #expect(AppLaunchRouter.surface(trigger: .coldStart, onboardingCompleted: false) == .onboarding)
    }
}
