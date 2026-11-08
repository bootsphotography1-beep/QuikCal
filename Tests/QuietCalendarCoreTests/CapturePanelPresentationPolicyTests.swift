import Testing
import Foundation
@testable import QuietCalendarCore

struct CapturePanelPresentationPolicyTests {

    // MARK: Level / privilege

    @Test func preferredLevelIsFloatingNotPrivileged() {
        #expect(CapturePanelPresentationPolicy.preferredWindowLevel == .floating)
        #expect(CapturePanelPresentationPolicy.preferredLevelIsAllowed)
        #expect(!CapturePanelPresentationPolicy.forbiddenWindowLevels.contains(.floating))
        #expect(CapturePanelPresentationPolicy.forbiddenWindowLevels.contains(.screenSaver))
        #expect(CapturePanelPresentationPolicy.forbiddenWindowLevels.contains(.statusBar))
        #expect(CapturePanelPresentationPolicy.forbiddenWindowLevels.contains(.modalPanel))
    }

    @Test func doesNotClaimSecureDesktopOrAXBypass() {
        #expect(CapturePanelPresentationPolicy.claimsSecureDesktopOrLockScreenOverlay == false)
        #expect(CapturePanelPresentationPolicy.usesAccessibilityToModifyOtherApps == false)
        #expect(CapturePanelPresentationPolicy.mayActivateAppForKeyFocus == true)
        #expect(CapturePanelPresentationPolicy.orderFrontRegardlessOnPresent == true)
    }

    // MARK: Spaces / deactivate — Apple mutual exclusivity

    @Test func spacesFlagsRespectAppleMutualExclusivity() {
        let flags = CapturePanelPresentationPolicy.collectionBehavior
        #expect(flags.canJoinAllSpaces == true)
        #expect(flags.fullScreenAuxiliary == true)
        #expect(flags.moveToActiveSpace == false)
        #expect(flags.isValidPerAppleSpacesExclusivity)
        #expect(
            CapturePanelPresentationPolicy.isValidSpacesCollectionBehavior(
                canJoinAllSpaces: true,
                moveToActiveSpace: false
            )
        )
        #expect(
            CapturePanelPresentationPolicy.isValidSpacesCollectionBehavior(
                canJoinAllSpaces: false,
                moveToActiveSpace: true
            )
        )
        #expect(
            !CapturePanelPresentationPolicy.isValidSpacesCollectionBehavior(
                canJoinAllSpaces: true,
                moveToActiveSpace: true
            )
        )
        #expect(CapturePanelPresentationPolicy.joinsAllSpaces)
        #expect(CapturePanelPresentationPolicy.fullScreenAuxiliary)
        #expect(CapturePanelPresentationPolicy.moveToActiveSpace == false)
        #expect(CapturePanelPresentationPolicy.hidesOnDeactivate == false)
        #expect(CapturePanelPresentationPolicy.isMovableByWindowBackground)
        #expect(CapturePanelPresentationPolicy.centerOnActiveDisplayEachInvocation)
        #expect(CapturePanelPresentationPolicy.becomesKeyForTextInput)
        #expect(CapturePanelPresentationPolicy.canBecomeMainWindow == false)
    }

    @Test func combiningCanJoinAllSpacesWithMoveToActiveSpaceIsInvalid() {
        let illegal = CapturePanelPresentationPolicy.CollectionBehaviorFlags(
            canJoinAllSpaces: true,
            fullScreenAuxiliary: true,
            moveToActiveSpace: true
        )
        #expect(!illegal.isValidPerAppleSpacesExclusivity)
    }

    // MARK: Dismiss / draft

    @Test func dismissReasonsPreserveDraftAndNeverWrite() {
        for reason in CapturePanelDismissReason.allCases {
            #expect(CapturePanelPresentationPolicy.preservesDraft(on: reason))
            #expect(CapturePanelPresentationPolicy.writesCalendar(on: reason) == false)
            #expect(CapturePanelPresentationPolicy.dismissReasonsPreservingDraftWithoutWrite.contains(reason))
        }
    }

    // MARK: Geometry helpers

    @Test func activeDisplayPrefersMouseScreen() {
        #expect(
            CapturePanelPresentationPolicy.activeDisplayIndex(mouseScreenIndex: 1, screenCount: 3) == 1
        )
        #expect(
            CapturePanelPresentationPolicy.activeDisplayIndex(mouseScreenIndex: nil, screenCount: 2) == 0
        )
        #expect(
            CapturePanelPresentationPolicy.activeDisplayIndex(mouseScreenIndex: 9, screenCount: 2) == 0
        )
        #expect(
            CapturePanelPresentationPolicy.activeDisplayIndex(mouseScreenIndex: 0, screenCount: 0) == nil
        )
    }

    @Test func centeredOriginLiftsSlightlyAboveTrueCenter() {
        let origin = CapturePanelPresentationPolicy.centeredOrigin(
            visibleFrameMinX: 100,
            visibleFrameMinY: 200,
            visibleFrameWidth: 1000,
            visibleFrameHeight: 800,
            panelWidth: 640,
            panelHeight: 120,
            opticalLiftFraction: 0.12
        )
        let expectedX = (100.0 + 1000.0 / 2.0) - 640.0 / 2.0
        let expectedY = (200.0 + 800.0 / 2.0) - 120.0 / 2.0 + 800.0 * 0.12
        #expect(origin.x == expectedX)
        #expect(origin.y == expectedY)
    }
}
