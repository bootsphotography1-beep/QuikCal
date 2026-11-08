import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.7: compact product copy for the Accessibility drag guide, QA
/// location fixtures that never fake the bundle path, install-first
/// compactness, and once-per-presentation pop policy. No GUI, no TCC.
@Suite("Accessibility Drag Polish 037")
struct AccessibilityDragPolish037Tests {
    private var bodyCopy: [String] {
        [AccessibilityDragGuideCopy.guideTitle,
         AccessibilityDragGuideCopy.guideSubtitle]
            + AccessibilityDragGuideCopy.steps
            + [AccessibilityDragGuideCopy.tileDragLabel,
               AccessibilityDragGuideCopy.appFileName,
               AccessibilityDragGuideCopy.alreadyListedHint,
               AccessibilityDragGuideCopy.dragDoesNotGrantShort,
               AccessibilityDragGuideCopy.approveNote,
               AccessibilityDragGuideCopy.manualNextNote,
               AccessibilityDragGuideCopy.detailsTitle]
    }

    @Test func defaultPageCopyIsShortProductCopy() {
        #expect(AccessibilityDragGuideCopy.guideTitle == "Enable hold-to-talk")
        #expect(AccessibilityDragGuideCopy.guideSubtitle == "Allow QuikCal to use your shortcut.")
        #expect(AccessibilityDragGuideCopy.steps == [
            "Open Accessibility settings.",
            "Drag QuikCal into the list if it’s missing.",
            "Turn on QuikCal, then return here."
        ])
        #expect(AccessibilityDragGuideCopy.tileDragLabel == "Drag to Accessibility")
        #expect(AccessibilityDragGuideCopy.openSettings == "Open Settings")
        #expect(AccessibilityDragGuideCopy.revealApp == "Reveal App")

        let count = AccessibilityDragGuideCopy.defaultInstructionalWordCount
        // QuikCal rebrand (2026-11-06) shortened two copy strings by one word
        // each; the page-length budget is unchanged in intent.
        #expect(count >= 55 && count <= 80)
        // Same computation independently, so the helper cannot drift.
        let recomputed = bodyCopy
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
            .count
        #expect(count == recomputed)
    }

    @Test func technicalDetailsLiveOnlyInTheDisclosure() {
        let body = bodyCopy.joined(separator: " ")
        for bodyForbidden in ["Apple menu", "authenticate", "Input Monitoring",
                              "Microphone", "Calendar use", "/Applications"] {
            #expect(!body.contains(bodyForbidden))
        }
        // …and the disclosure actually carries each required topic.
        #expect(AccessibilityDragGuideCopy.detailsManualPath.contains("Apple menu"))
        #expect(AccessibilityDragGuideCopy.detailsManualPath.contains("vary slightly by macOS version"))
        #expect(AccessibilityDragGuideCopy.detailsAuthentication.contains("authenticate"))
        #expect(AccessibilityDragGuideCopy.detailsMembership.contains("can’t see the Accessibility list"))
        #expect(AccessibilityDragGuideCopy.detailsMicCalendar.contains("Microphone and Calendar"))
        #expect(AccessibilityDragGuideCopy.detailsInputMonitoring.contains("required for the Fn shortcut"))
        #expect(AccessibilityDragGuideCopy.detailsAppLocation == "App location")
    }

    @Test func honestyCopyStillHolds() {
        // The visible page never claims that dragging approves the app.
        #expect(AccessibilityDragGuideCopy.dragDoesNotGrantShort.contains("doesn’t turn on Accessibility"))
        #expect(AccessibilityDragGuideCopy.approveNote == "You’ll approve this in System Settings.")
        #expect(AccessibilityDragGuideCopy.manualNextNote == "Next never advances on its own.")
        #expect(AccessibilityDragGuideCopy.dragDoesNotGrant.contains("does not turn on Accessibility"))
        #expect(AccessibilityDragGuideCopy.tileAccessibilityLabel.contains("does not turn on Accessibility"))
        // No copy may claim list membership knowledge.
        #expect(!bodyCopy.joined(separator: " ").contains("already in the list"))
    }

    @Test func developerNoticeIsConciseAndPathMovesToDetails() {
        #expect(AccessibilityDragGuideCopy.developerBuildNote == "Using a development copy")
        #expect(!AccessibilityDragGuideCopy.developerBuildNote.contains("path"))
        #expect(!AccessibilityDragGuideCopy.developerBuildNote.contains("/Applications"))
        #expect(AccessibilityDragGuideCopy.detailsAppLocation == "App location")
    }

    @Test func installFirstIsCompactAndOffersNoTransientDrag() {
        #expect(AccessibilityDragGuideCopy.installFirstTitle == "Install to Applications first.")
        let bodyWords = AccessibilityDragGuideCopy.installFirstBody
            .split(whereSeparator: { $0.isWhitespace }).count
        #expect(bodyWords <= 12)
        #expect(AccessibilityDragGuideCopy.installFirstBody.contains("Move QuikCal to Applications"))
        // Mounted/translocated copies are valid .app exports but must never
        // offer the drag tile — no transient Accessibility entry.
        for path in ["/Volumes/QuikCal/QuikCal.app",
                     "/private/var/folders/x/AppTranslocation/UUID/QuikCal.app"] {
            let payload = AccessibilityDragPayload(
                bundlePath: path, bundleID: "com.quietcalendar.app")
            #expect(payload.isValidExport)
            #expect(!payload.offersDragTile)
            #expect(payload.location.requiresInstallFirst)
        }
    }

    @Test func qaLocationFixtureKeepsTheRealBundlePath() {
        let realPath = "/Users/example/project/build/qa-037/QuikCal.app"
        let installedFixture = AccessibilityDragPayload(
            bundlePath: realPath,
            bundleID: "com.quietcalendar.app",
            locationOverride: .installedApplications
        )
        // The fixture only relabels the location; it never rewrites the
        // exported app path (no fake /Applications payload).
        #expect(installedFixture.bundlePath == realPath)
        #expect(installedFixture.location == .installedApplications)
        #expect(installedFixture.offersDragTile)
        #expect(!installedFixture.isDeveloperBuildCopy)

        let dmgFixture = AccessibilityDragPayload(
            bundlePath: realPath,
            bundleID: "com.quietcalendar.app",
            locationOverride: .mountedDiskImage
        )
        #expect(dmgFixture.bundlePath == realPath)
        #expect(!dmgFixture.offersDragTile)

        // Without an override, classification still comes from the path.
        let real = AccessibilityDragPayload(
            bundlePath: realPath, bundleID: "com.quietcalendar.app")
        #expect(real.location == .developerBuild)
        #expect(real.isDeveloperBuildCopy)
    }

    @Test func statusRowIsExplicitAndManual() {
        #expect(AccessibilityDragGuideCopy.notYetCheck == "Not yet")
        #expect(AccessibilityDragGuideCopy.enabledCheck == "Enabled")
        #expect(AccessibilityDragGuideCopy.trustedNextStep == "Enabled — you can continue.")
        #expect(AccessibilityDragGuideCopy.checkAgain == "Check again")
        // Status text alone never advances the guide; it only reflects the
        // authoritative AX flag.
        var guide = HoldToTalkGuideState(phase: .openSettings)
        guide.applyAccessibilityTrusted(true)
        #expect(guide.phase == .openSettings)
        #expect(guide.accessibilityRecheck == .granted)
        guide.applyAccessibilityTrusted(false)
        #expect(guide.phase == .openSettings)
    }

    @Test func guidePhaseTitleUsesTheProductTitle() {
        #expect(HoldToTalkGuidePhase.openSettings.title == AccessibilityDragGuideCopy.guideTitle)
        // No technical title leaks into the page header.
        #expect(HoldToTalkGuidePhase.openSettings.title != "Open System Settings")
    }

    @Test func popStillOncePerPresentationWithReduceMotionFade() {
        let normal = OnboardingPopAnimationSpec.spec(reduceMotion: false)
        #expect(normal.initialScale == 0.94)
        #expect(normal.finalScale == 1.0)
        #expect(normal.durationSeconds == 0.28)
        #expect(!normal.fadeOnly)
        let reduced = OnboardingPopAnimationSpec.spec(reduceMotion: true)
        #expect(reduced.fadeOnly)
        #expect(reduced.initialScale == reduced.finalScale)
        #expect(reduced.durationSeconds == 0.12)

        var tracker = OnboardingPresentationTracker()
        let id = tracker.presentationID
        // Step / download / focus updates never mint a new presentation.
        for _ in 0..<5 { #expect(tracker.refreshedWithoutReanimating() == id) }
        #expect(tracker.newPresentation() != id)
    }
}
