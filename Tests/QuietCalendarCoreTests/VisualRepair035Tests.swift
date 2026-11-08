import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.5 menu-bar coachmark geometry: full-frame validation (menu bar
/// included) + visible-frame callout placement. Realistic screen geometry,
/// not framework-free fiction — the primary case is the exact shape that
/// failed in 0.3.4 (target above visibleFrame, inside full frame).
@Suite("Visual Repair 035 — menu-bar coachmark geometry")
struct VisualRepair035Tests {

    @Test func primaryScreenMenuBarTargetAnchors() {
        // Realistic primary: full (0,0,1440,900), visible (0,0,1440,875)
        // (25 pt menu bar excluded), status item at top-right y 878..900.
        let full = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = ScreenRect(x: 0, y: 0, width: 1440, height: 875)
        let target = ScreenRect(x: 1330, y: 878, width: 60, height: 22)
        // Sanity: this is the 0.3.4 failure shape — target does NOT
        // intersect visibleFrame, but DOES intersect fullFrame.
        #expect(target.y >= visible.maxY)
        let layout = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: target,
            visibleFrame: visible,
            fullFrame: full,
            cardSize: ScreenSize(width: 340, height: 196)
        )
        #expect(layout.isAnchored)
        // Ring hugs the real target (expanded 8 pt), in the menu-bar strip.
        #expect(layout.ringRect?.x == 1322)
        #expect(layout.ringRect?.y == 870)
        #expect((layout.ringRect?.maxY ?? 0) > visible.maxY) // extends into menu bar — not clipped away
        #expect((layout.ringRect?.maxY ?? 0) <= full.maxY)
        // Card below the ring, inside the visible frame.
        #expect(layout.cardOrigin.y >= visible.y)
        #expect(layout.cardOrigin.y + layout.cardSize.height <= visible.maxY)
        #expect(layout.cardOrigin.x >= visible.x)
        #expect(layout.cardOrigin.x + layout.cardSize.width <= visible.maxX)
        // Card is below the ring (menu bar at top).
        #expect(layout.cardOrigin.y + layout.cardSize.height <= (layout.ringRect?.y ?? 0) + 0.5)
        // Arrow actually points at the real icon: tip on ring bottom edge,
        // x at the target centre; base on the card top edge.
        #expect(layout.targetCenter?.x == 1360)
        #expect(layout.arrowTip?.x == 1360)
        #expect(layout.arrowTip?.y == layout.ringRect?.y)
        #expect(layout.arrowBaseCenter?.y == layout.cardOrigin.y + layout.cardSize.height)
    }

    @Test func secondaryNegativeOriginAnchorsAndClamps() {
        // Secondary monitor left of primary: negative origin, menu bar on top.
        let full = ScreenRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visible = ScreenRect(x: -1920, y: 0, width: 1920, height: 1055)
        let target = ScreenRect(x: -180, y: 1058, width: 60, height: 22)
        let layout = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: target,
            visibleFrame: visible,
            fullFrame: full,
            cardSize: ScreenSize(width: 340, height: 196)
        )
        #expect(layout.isAnchored)
        #expect(layout.ringRect?.x == -188)
        #expect(layout.arrowTip?.x == -150)
        // Callout clamped inside the visible frame (right edge at x=0).
        #expect(layout.cardOrigin.x >= -1920)
        #expect(layout.cardOrigin.x + 340 <= 0)
        #expect(layout.cardOrigin.y >= 0)
        #expect(layout.cardOrigin.y + 196 <= 1055)
    }

    @Test func leftAndRightOverflowCalloutClampedButStillTargeting() {
        let full = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = ScreenRect(x: 0, y: 0, width: 1440, height: 875)
        // Far right: card would overflow right if centred on target.
        let right = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: ScreenRect(x: 1400, y: 878, width: 36, height: 22),
            visibleFrame: visible, fullFrame: full,
            cardSize: ScreenSize(width: 340, height: 196)
        )
        #expect(right.isAnchored)
        #expect(right.cardOrigin.x + 340 <= 1440)
        #expect(right.cardOrigin.x >= 0)
        // Arrow tip still at the real target centre, not the card centre.
        #expect(right.arrowTip?.x == 1418)
        #expect(right.arrowTip?.y == right.ringRect?.y)
        // Far left: card would overflow left if centred on target.
        let left = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: ScreenRect(x: 4, y: 878, width: 36, height: 22),
            visibleFrame: visible, fullFrame: full,
            cardSize: ScreenSize(width: 340, height: 196)
        )
        #expect(left.isAnchored)
        #expect(left.cardOrigin.x >= 0)
        #expect(left.arrowTip?.x == 22)
    }

    @Test func hiddenZeroNonFiniteAndOffscreenTargetsFallback() {
        let full = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = ScreenRect(x: 0, y: 0, width: 1440, height: 875)
        let card = ScreenSize(width: 340, height: 196)
        // Missing (hidden menu bar / notch — no button frame).
        let missing = MenuBarCoachmarkGeometry.layout(targetScreenFrame: nil, visibleFrame: visible, fullFrame: full, cardSize: card)
        #expect(!missing.isAnchored && missing.ringRect == nil && missing.arrowTip == nil)
        // Zero-size.
        let zero = MenuBarCoachmarkGeometry.layout(targetScreenFrame: ScreenRect(x: 100, y: 880, width: 0, height: 0), visibleFrame: visible, fullFrame: full, cardSize: card)
        #expect(!zero.isAnchored)
        // Non-finite.
        let nan = MenuBarCoachmarkGeometry.layout(targetScreenFrame: ScreenRect(x: .nan, y: 880, width: 60, height: 22), visibleFrame: visible, fullFrame: full, cardSize: card)
        #expect(!nan.isAnchored)
        let inf = MenuBarCoachmarkGeometry.layout(targetScreenFrame: ScreenRect(x: 100, y: 880, width: .infinity, height: 22), visibleFrame: visible, fullFrame: full, cardSize: card)
        #expect(!inf.isAnchored)
        // Entirely offscreen (outside the FULL frame).
        let off = MenuBarCoachmarkGeometry.layout(targetScreenFrame: ScreenRect(x: 5000, y: 5000, width: 60, height: 22), visibleFrame: visible, fullFrame: full, cardSize: card)
        #expect(!off.isAnchored)
        // Fallback card stays inside the visible frame in every case.
        for layout in [missing, zero, nan, inf, off] {
            #expect(layout.cardOrigin.x >= visible.x)
            #expect(layout.cardOrigin.x + layout.cardSize.width <= visible.maxX)
            #expect(layout.cardOrigin.y >= visible.y)
            #expect(layout.cardOrigin.y + layout.cardSize.height <= visible.maxY)
        }
    }

    @Test func legacyCallWithoutFullFrameStillWorks() {
        // Old call shape (no fullFrame) keeps working: full defaults to visible.
        let visible = ScreenRect(x: 0, y: 0, width: 1512, height: 950)
        let layout = MenuBarCoachmarkGeometry.layout(
            targetScreenFrame: ScreenRect(x: 700, y: 920, width: 60, height: 24),
            visibleFrame: visible,
            cardSize: ScreenSize(width: 340, height: 196)
        )
        #expect(layout.isAnchored)
    }
}
