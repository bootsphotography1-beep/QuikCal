import Foundation

/// Symbolic window level for the floating capture panel.
/// Maps to AppKit `NSWindow.Level` in the UI target — kept AppKit-free for unit tests.
public enum CapturePanelWindowLevelChoice: String, Sendable, Equatable, CaseIterable {
    /// Supported Spotlight-like HUD above ordinary app windows.
    case floating
    /// Forbidden — excessively privileged; used by screen savers / shields.
    case screenSaver
    /// Forbidden — status-item chrome, not a capture HUD.
    case statusBar
    /// Forbidden — modal session elevation beyond a soft overlay.
    case modalPanel
    /// Normal document window — appears *behind* the frontmost app when QuikCal is inactive.
    case normal
}

/// How the panel may dismiss without writing a calendar event.
public enum CapturePanelDismissReason: String, Sendable, Equatable, CaseIterable {
    case escape
    case outsideClick
    case toggleClosed
    /// 0.3.21 gear fix: the capture bar hands off to another QuikCal window
    /// (Settings / onboarding opened from the bar's gear). The floating bar
    /// must hide BEFORE the destination window comes up, or it stays above
    /// it at the floating level and the user is trapped. Same draft safety
    /// as every other dismiss: input preserved, nothing written.
    case settingsHandoff
}

/// Pure presentation policy for the Spotlight-style capture overlay.
///
/// Owner requirement: panel appears over foreground apps (like Spotlight), not only when
/// QuikCal is focused — using supported `NSPanel` floating level + Spaces behaviors.
/// Does **not** claim lock-screen / secure-desktop overlay, Accessibility bypass, or
/// modification of other apps.
///
/// Apple Spaces collection behaviors (`canJoinAllSpaces` vs `moveToActiveSpace`) are
/// **mutually exclusive** — Window Programming Guide: set at most one Spaces option.
/// QuikCal uses `canJoinAllSpaces` + `fullScreenAuxiliary` (Spotlight-like presence
/// on all Spaces, including full-screen auxiliary where macOS permits).
public enum CapturePanelPresentationPolicy: Sendable {

    // MARK: Level / Spaces

    /// Preferred AppKit level for the capture HUD.
    public static let preferredWindowLevel: CapturePanelWindowLevelChoice = .floating

    /// Levels QuikCal must never request for capture.
    public static let forbiddenWindowLevels: Set<CapturePanelWindowLevelChoice> = [
        .screenSaver, .statusBar, .modalPanel
    ]

    public static var preferredLevelIsAllowed: Bool {
        !forbiddenWindowLevels.contains(preferredWindowLevel)
            && preferredWindowLevel != .normal
    }

    /// `NSWindow.CollectionBehavior.canJoinAllSpaces`
    public static let joinsAllSpaces = true
    /// `NSWindow.CollectionBehavior.fullScreenAuxiliary` — appear with full-screen Spaces where macOS permits.
    public static let fullScreenAuxiliary = true
    /// `NSWindow.CollectionBehavior.moveToActiveSpace` — **must stay false** when `joinsAllSpaces` is true
    /// (Apple mutual exclusivity for Spaces collection behaviors).
    public static let moveToActiveSpace = false

    /// Panel remains visible when QuikCal is not the active app.
    public static let hidesOnDeactivate = false

    /// Borderless floating panel may become key for the capture text field.
    public static let becomesKeyForTextInput = true
    public static let canBecomeMainWindow = false

    // MARK: Summon / layout

    /// Re-center on the active display every time the panel is summoned (Spotlight-like).
    /// User may still drag while visible; next summon re-centers.
    public static let centerOnActiveDisplayEachInvocation = true

    /// Keep the panel draggable by window background while visible.
    public static let isMovableByWindowBackground = true

    // MARK: Activation / key focus

    /// Brief `NSApp.activate(ignoringOtherApps:)` is allowed so the text field can become first responder.
    /// QuikCal must not use Accessibility to steal or rewrite other apps’ UI.
    public static let mayActivateAppForKeyFocus = true
    public static let usesAccessibilityToModifyOtherApps = false

    /// Prefer `orderFrontRegardless` before key transfer so the HUD is not trapped behind the front app.
    public static let orderFrontRegardlessOnPresent = true

    // MARK: Secure surfaces / claims

    /// Do not claim ability to draw over lock screen, loginwindow, or other system-secure shields.
    public static let claimsSecureDesktopOrLockScreenOverlay = false

    // MARK: Dismiss / draft safety

    /// Escape and outside-click dismiss must preserve the in-memory draft and never auto-write.
    public static func preservesDraft(on reason: CapturePanelDismissReason) -> Bool {
        switch reason {
        case .escape, .outsideClick, .toggleClosed, .settingsHandoff:
            return true
        }
    }

    public static func writesCalendar(on reason: CapturePanelDismissReason) -> Bool {
        false
    }

    public static let dismissReasonsPreservingDraftWithoutWrite: Set<CapturePanelDismissReason> = [
        .escape, .outsideClick, .toggleClosed, .settingsHandoff
    ]

    // MARK: Collection behavior bitmask (testable flags)

    public struct CollectionBehaviorFlags: Sendable, Equatable {
        public var canJoinAllSpaces: Bool
        public var fullScreenAuxiliary: Bool
        public var moveToActiveSpace: Bool

        public init(
            canJoinAllSpaces: Bool = CapturePanelPresentationPolicy.joinsAllSpaces,
            fullScreenAuxiliary: Bool = CapturePanelPresentationPolicy.fullScreenAuxiliary,
            moveToActiveSpace: Bool = CapturePanelPresentationPolicy.moveToActiveSpace
        ) {
            self.canJoinAllSpaces = canJoinAllSpaces
            self.fullScreenAuxiliary = fullScreenAuxiliary
            self.moveToActiveSpace = moveToActiveSpace
        }

        /// Apple Window Programming Guide: Spaces options are mutually exclusive —
        /// at most one of `canJoinAllSpaces` / `moveToActiveSpace` (or neither = default).
        public var isValidPerAppleSpacesExclusivity: Bool {
            CapturePanelPresentationPolicy.isValidSpacesCollectionBehavior(
                canJoinAllSpaces: canJoinAllSpaces,
                moveToActiveSpace: moveToActiveSpace
            )
        }
    }

    /// Authoritative Spaces exclusivity check (Apple: only one Spaces collection behavior).
    public static func isValidSpacesCollectionBehavior(
        canJoinAllSpaces: Bool,
        moveToActiveSpace: Bool
    ) -> Bool {
        !(canJoinAllSpaces && moveToActiveSpace)
    }

    public static let collectionBehavior = CollectionBehaviorFlags()

    /// Active-display pick for centering: prefer screen under the mouse, else primary.
    public static func activeDisplayIndex(
        mouseScreenIndex: Int?,
        screenCount: Int
    ) -> Int? {
        guard screenCount > 0 else { return nil }
        if let mouseScreenIndex, mouseScreenIndex >= 0, mouseScreenIndex < screenCount {
            return mouseScreenIndex
        }
        return 0
    }

    /// Origin that centers `panelSize` in `visibleFrame`, with a slight optical lift (Spotlight-ish).
    public static func centeredOrigin(
        visibleFrameMinX: Double,
        visibleFrameMinY: Double,
        visibleFrameWidth: Double,
        visibleFrameHeight: Double,
        panelWidth: Double,
        panelHeight: Double,
        opticalLiftFraction: Double = 0.12
    ) -> (x: Double, y: Double) {
        let midX = visibleFrameMinX + visibleFrameWidth / 2
        let midY = visibleFrameMinY + visibleFrameHeight / 2
        return (
            x: midX - panelWidth / 2,
            y: midY - panelHeight / 2 + visibleFrameHeight * opticalLiftFraction
        )
    }
}
