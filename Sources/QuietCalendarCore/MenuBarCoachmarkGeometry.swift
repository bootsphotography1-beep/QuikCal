import Foundation

/// Pure screen-space rect in AppKit coordinates (origin bottom-left,
/// negative origins allowed on multi-monitor setups). Plain doubles —
/// no Foundation geometry helpers — so the layout policy is fully
/// unit-testable without AppKit or a display.
public struct ScreenRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct ScreenPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ScreenSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Pure geometry for the final menu-bar coachmark. No AppKit, no private API,
/// no hardcoded pixel position and no screenshot matching — the only anchor is
/// the **real** `NSStatusItem.button` frame supplied by the caller in screen
/// coordinates. Testable without a display.
///
/// 0.3.5 root-cause fix: the menu-bar target lives in the menu-bar strip,
/// which `NSScreen.visibleFrame` *excludes* by definition. The 0.3.4 layout
/// required the target to intersect `visibleFrame`, so the anchored branch
/// was unreachable on every normal display and the fallback always won.
/// This layout therefore validates the target against the **full** screen
/// frame (`NSScreen.frame`, which includes the menu bar) and uses
/// `visibleFrame` only to place/clamp the callout card.
///
/// - anchored: ring hugs the real target frame (expanded, clipped to the
///   full frame so the menu-bar strip is drawable); an arrow runs from the
///   card edge nearest the target to the target's own centre; the card is
///   placed below the ring when it fits in the visible frame, otherwise
///   above it, horizontally clamped inside the visible frame.
/// - fallback: target missing / non-finite / zero-size / not intersecting
///   the *full* frame (hidden, offscreen, or the button frame is missing,
///   e.g. menu bar hidden by a fullscreen app / notch) → no ring, no arrow,
///   card centered at the top of the visible frame with written
///   instructions. Never points offscreen.
public struct MenuBarCoachmarkLayout: Sendable, Equatable {
    /// Ring rect in screen coordinates (nil = fallback, draw no ring).
    public var ringRect: ScreenRect?
    /// Card origin (lower-left) in screen coordinates.
    public var cardOrigin: ScreenPoint
    public var cardSize: ScreenSize
    public var isAnchored: Bool
    /// Real target centre in screen coordinates (nil = fallback).
    public var targetCenter: ScreenPoint?
    /// Arrow tip: the point on the (expanded) target/ring nearest the card,
    /// on the line toward the target centre. Nil = fallback.
    public var arrowTip: ScreenPoint?
    /// Arrow base centre: the point on the card edge nearest the target.
    /// Nil = fallback.
    public var arrowBaseCenter: ScreenPoint?

    public init(
        ringRect: ScreenRect?,
        cardOrigin: ScreenPoint,
        cardSize: ScreenSize,
        isAnchored: Bool,
        targetCenter: ScreenPoint? = nil,
        arrowTip: ScreenPoint? = nil,
        arrowBaseCenter: ScreenPoint? = nil
    ) {
        self.ringRect = ringRect
        self.cardOrigin = cardOrigin
        self.cardSize = cardSize
        self.isAnchored = isAnchored
        self.targetCenter = targetCenter
        self.arrowTip = arrowTip
        self.arrowBaseCenter = arrowBaseCenter
    }
}

public enum MenuBarCoachmarkGeometry: Sendable {
    /// Gap between ring and card, and ring expansion around the target.
    public static let ringExpansion: Double = 8
    public static let cardGap: Double = 16
    public static let minCardWidth: Double = 280

    /// - Parameters:
    ///   - targetScreenFrame: real status-item button frame in screen coords, or nil.
    ///   - visibleFrame: `NSScreen.visibleFrame` of the hosting screen. Used
    ///     ONLY for callout placement/clamping — it excludes the menu bar.
    ///   - fullFrame: `NSScreen.frame` of the hosting screen (includes the
    ///     menu bar). Used ONLY to validate/draw against the real target.
    ///     Defaults to `visibleFrame` for legacy callers that have no full
    ///     frame available.
    ///   - cardSize: desired card size.
    public static func layout(
        targetScreenFrame: ScreenRect?,
        visibleFrame: ScreenRect,
        fullFrame: ScreenRect? = nil,
        cardSize: ScreenSize
    ) -> MenuBarCoachmarkLayout {
        let full = fullFrame ?? visibleFrame
        let size = ScreenSize(
            width: max(cardSize.width, minCardWidth),
            height: cardSize.height
        )
        guard isFiniteRect(visibleFrame), visibleFrame.width > 0, visibleFrame.height > 0,
              isFiniteRect(full), full.width > 0, full.height > 0,
              let target = targetScreenFrame,
              isFiniteRect(target),
              target.width > 0, target.height > 0,
              rectsIntersect(target, full)
        else {
            // Fallback: centered at the top of the visible frame (AppKit
            // coordinates grow upward, so "top" = near maxY). Never offscreen.
            let origin = ScreenPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - 12
            )
            return MenuBarCoachmarkLayout(
                ringRect: nil,
                cardOrigin: clamped(origin, cardSize: size, in: visibleFrame),
                cardSize: size,
                isAnchored: false
            )
        }

        let expanded = ScreenRect(
            x: target.x - ringExpansion,
            y: target.y - ringExpansion,
            width: target.width + ringExpansion * 2,
            height: target.height + ringExpansion * 2
        )
        // Clip to the FULL frame (menu bar included), not the visible frame.
        let ring = intersected(expanded, full)

        // Prefer below the ring (menu bar is at the top of the screen);
        // fall back to above when there is no room below in the visible frame.
        let belowY = ring.y - cardGap - size.height
        let rawOrigin: ScreenPoint
        if belowY >= visibleFrame.y {
            rawOrigin = ScreenPoint(x: ring.midX - size.width / 2, y: belowY)
        } else {
            rawOrigin = ScreenPoint(x: ring.midX - size.width / 2, y: ring.maxY + cardGap)
        }
        let origin = clamped(rawOrigin, cardSize: size, in: visibleFrame)

        // Arrow: from the card edge nearest the target to the target centre.
        // Tip = point on the ring edge nearest the card, shifted toward the
        // target's midX so the arrow actually points at the real icon even
        // when the card had to be clamped horizontally.
        let targetCenter = ScreenPoint(x: target.midX, y: target.midY)
        let cardBelowTarget = origin.y + size.height <= ring.y + 0.5
        let tip: ScreenPoint
        let base: ScreenPoint
        if cardBelowTarget {
            tip = ScreenPoint(x: clamp(targetCenter.x, in: ring.x...ring.maxX), y: ring.y)
            base = ScreenPoint(x: clamp(targetCenter.x, in: origin.x...origin.x + size.width), y: origin.y + size.height)
        } else {
            tip = ScreenPoint(x: clamp(targetCenter.x, in: ring.x...ring.maxX), y: ring.maxY)
            base = ScreenPoint(x: clamp(targetCenter.x, in: origin.x...origin.x + size.width), y: origin.y)
        }

        return MenuBarCoachmarkLayout(
            ringRect: ring,
            cardOrigin: origin,
            cardSize: size,
            isAnchored: true,
            targetCenter: targetCenter,
            arrowTip: tip,
            arrowBaseCenter: base
        )
    }

    private static func clamp(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func isFiniteRect(_ r: ScreenRect) -> Bool {
        r.x.isFinite && r.y.isFinite && r.width.isFinite && r.height.isFinite
    }

    private static func clamped(_ origin: ScreenPoint, cardSize: ScreenSize, in visibleFrame: ScreenRect) -> ScreenPoint {
        let x: Double
        if cardSize.width >= visibleFrame.width {
            x = visibleFrame.x
        } else {
            x = min(max(origin.x, visibleFrame.x), visibleFrame.maxX - cardSize.width)
        }
        let y: Double
        if cardSize.height >= visibleFrame.height {
            y = visibleFrame.y
        } else {
            y = min(max(origin.y, visibleFrame.y), visibleFrame.maxY - cardSize.height)
        }
        return ScreenPoint(x: x, y: y)
    }

    private static func rectsIntersect(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        a.x < b.maxX && a.maxX > b.x && a.y < b.maxY && a.maxY > b.y
    }

    private static func intersected(_ a: ScreenRect, _ b: ScreenRect) -> ScreenRect {
        let x = max(a.x, b.x)
        let y = max(a.y, b.y)
        let w = min(a.maxX, b.maxX) - x
        let h = min(a.maxY, b.maxY) - y
        return ScreenRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }
}
