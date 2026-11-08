import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.21 Spotlight-capsule regression tests (source only — not run as part
/// of the 0.3.21 bounded release pass; run in the next full test batch).
///
/// Covers the pure sizing policy for the redesigned capture bar and the
/// new draft-preserving `.settingsHandoff` dismiss reason that fixes the
/// gear focus trap (capture bar floating above Settings with no escape).
struct CaptureBarSizing0321Tests {

    // MARK: Width — fixed, clamped to screen, no live word-driven width

    @Test func barWidthIsFixedAndClampedToScreen() {
        #expect(CaptureBarSizingPolicy.preferredBarWidth == 640)
        // Normal desktop: the conceptual Spotlight width, unchanged.
        #expect(CaptureBarSizingPolicy.barWidth(visibleFrameWidth: 1440) == 640)
        #expect(CaptureBarSizingPolicy.barWidth(visibleFrameWidth: 700) == 640)
        // Narrow screen: never wider than the visible frame minus margins.
        #expect(CaptureBarSizingPolicy.barWidth(visibleFrameWidth: 500)
                 == 500 - CaptureBarSizingPolicy.screenMargin * 2)
        // Absurdly narrow: still a usable minimum.
        #expect(CaptureBarSizingPolicy.barWidth(visibleFrameWidth: 100) == 320)
    }

    // MARK: Height — single-line capsule, discrete downward growth

    @Test func singleLineCapsuleIsCompact() {
        #expect(CaptureBarSizingPolicy.capsuleHeight == 64)
        #expect(
            CaptureBarSizingPolicy.barHeight(inputLineCount: 1, hasStatusStrip: false) == 64
        )
    }

    @Test func growthIsDiscretePerLineAndStatusOnly() {
        let two = CaptureBarSizingPolicy.barHeight(inputLineCount: 2, hasStatusStrip: false)
        #expect(two == 64 + CaptureBarSizingPolicy.lineAdvance)
        let three = CaptureBarSizingPolicy.barHeight(inputLineCount: 3, hasStatusStrip: true)
        #expect(three == 64 + 2 * CaptureBarSizingPolicy.lineAdvance
                + CaptureBarSizingPolicy.statusStripHeight)
        // Non-positive line counts fall back to the single-line capsule.
        #expect(CaptureBarSizingPolicy.barHeight(inputLineCount: 0, hasStatusStrip: false) == 64)
    }

    @Test func heightClampKeepsCapsuleOnScreenAndNeverBelowMinimum() {
        let available: CGFloat = 400
        // Unclamped request fits.
        #expect(CaptureBarSizingPolicy.clampedHeight(requested: 116, availableHeight: available) == 116)
        // Oversized request clamps to the screen minus margins.
        #expect(
            CaptureBarSizingPolicy.clampedHeight(requested: 900, availableHeight: available)
                 == available - CaptureBarSizingPolicy.screenMargin * 2
        )
        // The single-line minimum always survives, even on a tiny screen.
        #expect(CaptureBarSizingPolicy.clampedHeight(requested: 64, availableHeight: 40) == 64)
        #expect(CaptureBarSizingPolicy.clampedHeight(requested: 10, availableHeight: 40) == 64)
    }

    @Test func lineCountFromMeasuredHeightsIsFontMetricIndependent() {
        let single: CGFloat = 24
        // Exactly one line.
        #expect(CaptureBarSizingPolicy.lineCount(measuredInputHeight: single, measuredSingleLineHeight: single) == 1)
        // Just past one line → two.
        #expect(CaptureBarSizingPolicy.lineCount(measuredInputHeight: single + 1, measuredSingleLineHeight: single) == 2)
        // Two full lines → two.
        #expect(
            CaptureBarSizingPolicy.lineCount(
                measuredInputHeight: single + CaptureBarSizingPolicy.lineAdvance,
                measuredSingleLineHeight: single
            ) == 2
        )
        // Capped at the input line limit (beyond it the field scrolls).
        #expect(
            CaptureBarSizingPolicy.lineCount(
                measuredInputHeight: single + 20 * CaptureBarSizingPolicy.lineAdvance,
                measuredSingleLineHeight: single
            ) == CaptureBarSizingPolicy.inputLineLimit.upperBound
        )
        // Guard: a zero reference height can never divide by zero.
        #expect(CaptureBarSizingPolicy.lineCount(measuredInputHeight: 50, measuredSingleLineHeight: 0) == 1)
    }

    // MARK: Settings handoff — the gear focus-trap fix

    @Test func settingsHandoffPreservesDraftAndNeverWrites() {
        #expect(CapturePanelPresentationPolicy.preservesDraft(on: .settingsHandoff))
        #expect(!CapturePanelPresentationPolicy.writesCalendar(on: .settingsHandoff))
        #expect(
            CapturePanelPresentationPolicy.dismissReasonsPreservingDraftWithoutWrite
                .contains(.settingsHandoff)
        )
    }

    @Test func everyDismissReasonStillPreservesDraftWithoutWrite() {
        for reason in CapturePanelDismissReason.allCases {
            #expect(CapturePanelPresentationPolicy.preservesDraft(on: reason))
            #expect(CapturePanelPresentationPolicy.writesCalendar(on: reason) == false)
            #expect(
                CapturePanelPresentationPolicy.dismissReasonsPreservingDraftWithoutWrite
                    .contains(reason)
            )
        }
    }
}
