import Foundation

/// Pure sizing policy for the 0.3.21 Spotlight-style capture capsule.
///
/// Owner requirement (2026-11-08, user screenshots): the capture state is a
/// SINGLE compact horizontally elongated capsule — conceptually ~620×64 pt
/// clamped to the screen — with a fixed width (no live word-driven width
/// changes), a leading icon, a large readable input, and compact trailing
/// controls. Long input wraps and the capsule grows DOWNWARD (top edge
/// anchored) within the available screen; beyond the clamp the input field
/// scrolls internally. Confirmation / day-schedule states remain the
/// existing expanded review surfaces — never crammed into the capsule.
///
/// Kept AppKit-free so unit tests can verify every number.
public enum CaptureBarSizingPolicy: Sendable {

    // MARK: Bar geometry

    /// Conceptual capsule width (Spotlight-like). Kept at the app's
    /// existing 640 pt so expanding into the confirmation review does not
    /// shift the horizontal anchor.
    public static let preferredBarWidth: CGFloat = 640

    /// Single-line capsule height — the compact Spotlight look.
    public static let capsuleHeight: CGFloat = 64

    /// Vertical growth per additional wrapped input line.
    public static let lineAdvance: CGFloat = 26

    /// Height of the concise status strip (clarification / errors /
    /// destination hints) shown inside the capsule, below the input.
    public static let statusStripHeight: CGFloat = 22

    /// Height of the am/pm candidate chip row (0.3.22) shown under a
    /// meridiem-ambiguous clarification ("six o'clock", "3:00").
    public static let chipStripHeight: CGFloat = 30

    /// Screen-edge margin when clamping width/height to a display.
    public static let screenMargin: CGFloat = 16

    /// Input line-limit for wrapping before the field scrolls internally.
    public static let inputLineLimit: ClosedRange<Int> = 1...5

    // MARK: Width

    /// Bar width clamped to the visible frame (never wider than the
    /// screen minus margins; never below a usable minimum).
    public static func barWidth(visibleFrameWidth: CGFloat) -> CGFloat {
        let usable = visibleFrameWidth - screenMargin * 2
        return min(preferredBarWidth, max(usable, 320))
    }

    // MARK: Height

    /// Unclamped capsule height for a wrapped input of `inputLineCount`
    /// lines plus an optional status strip and am/pm chip row.
    public static func barHeight(
        inputLineCount: Int,
        hasStatusStrip: Bool,
        hasChipRow: Bool = false
    ) -> CGFloat {
        let lines = max(1, inputLineCount)
        let inputExtra = CGFloat(lines - 1) * lineAdvance
        return capsuleHeight
            + inputExtra
            + (hasStatusStrip ? statusStripHeight : 0)
            + (hasChipRow ? chipStripHeight : 0)
    }

    /// Clamp a requested capsule height to the available screen height
    /// (minus margins). The single-line minimum is always kept; growth
    /// beyond the clamp becomes internal input scrolling in the view.
    public static func clampedHeight(
        requested: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let ceiling = max(availableHeight - screenMargin * 2, capsuleHeight)
        return min(max(requested, capsuleHeight), ceiling)
    }

    /// Line count implied by a measured wrapped-text height versus the
    /// measured single-line height (both measured with the SAME font, so
    /// the arithmetic is font-metric independent).
    public static func lineCount(
        measuredInputHeight: CGFloat,
        measuredSingleLineHeight: CGFloat
    ) -> Int {
        guard measuredSingleLineHeight > 0 else { return 1 }
        let extra = max(0, measuredInputHeight - measuredSingleLineHeight)
        let lines = 1 + Int((extra / lineAdvance).rounded(.up))
        return max(1, min(lines, inputLineLimit.upperBound))
    }
}
