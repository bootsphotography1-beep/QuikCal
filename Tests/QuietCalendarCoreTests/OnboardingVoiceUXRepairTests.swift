import Testing
import Foundation
@testable import QuietCalendarCore

/// Onboarding voice/UX repair (0.3.9 follow-up): compact listening pill,
/// two-decimal GB progress copy, concise blocked reasons, and honest
/// Accessibility-mismatch diagnosis. Pure policies only — no live capture,
/// no TCC access, no real permission changes.
struct OnboardingVoiceUXRepairTests {

    // MARK: Progress copy — two-decimal GB, never raw bytes

    @Test func gigabytesUsesTwoDecimals() {
        #expect(VoiceOverlayPolicy.gigabytes(731_400_000) == "0.73 GB")
        #expect(VoiceOverlayPolicy.gigabytes(3_472_295_456) == "3.47 GB")
        #expect(VoiceOverlayPolicy.gigabytes(0) == "0.00 GB")
        #expect(VoiceOverlayPolicy.gigabytes(-5) == "0.00 GB")
    }

    @Test func progressLabelMatchesOwnerExample() {
        #expect(
            VoiceOverlayPolicy.progressLabel(received: 731_400_000, total: 3_472_295_456)
                == "0.73 out of 3.47 GB"
        )
    }

    @Test func progressLabelNeverShowsRawBytesOrOverrun() {
        let label = VoiceOverlayPolicy.progressLabel(received: 999_999, total: 3_472_295_456)
        #expect(!label.contains("bytes"))
        #expect(label == "0.00 out of 3.47 GB")
        // Over-reads clamp to the total (defensive; no 100.2%).
        #expect(
            VoiceOverlayPolicy.progressLabel(received: 4_000_000_000, total: 3_472_295_456)
                == "3.47 out of 3.47 GB"
        )
        // Unknown total degrades honestly.
        #expect(VoiceOverlayPolicy.progressLabel(received: 731_400_000, total: 0) == "0.73 GB downloaded")
    }

    // MARK: Pill placement — top-center, notch / multi-screen safe

    @Test func pillIsCenteredBelowVisibleTop() {
        let origin = VoiceOverlayPolicy.pillOrigin(
            visibleFrameMinX: 0, visibleFrameMinY: 0,
            visibleFrameWidth: 1440, visibleFrameHeight: 900,
            pillWidth: 260, pillHeight: 44
        )
        #expect(origin.x == (1440 - 260) / 2)
        // macOS y-up: top of visible frame minus pill minus inset.
        #expect(origin.y == 900 - 44 - 12)
    }

    @Test func pillStaysInsideVisibleFrameOnNarrowScreens() {
        // Narrower than the pill: clamped to the visible left edge, never
        // negative / off-screen, never under the menu bar (visibleFrame
        // already excludes it — the notch region).
        let origin = VoiceOverlayPolicy.pillOrigin(
            visibleFrameMinX: 0, visibleFrameMinY: 0,
            visibleFrameWidth: 200, visibleFrameHeight: 60,
            pillWidth: 260, pillHeight: 44
        )
        #expect(origin.x == 0)
        #expect(origin.y >= 0)
        #expect(origin.y + 44 <= 60)
    }

    @Test func pillRespectsOffsetVisibleFrame() {
        // Multi-screen: a display to the right of the main one has a
        // positive minX; the pill centers inside THAT frame.
        let origin = VoiceOverlayPolicy.pillOrigin(
            visibleFrameMinX: 1920, visibleFrameMinY: 0,
            visibleFrameWidth: 1920, visibleFrameHeight: 1000,
            pillWidth: 260, pillHeight: 44
        )
        #expect(origin.x == 1920 + (1920 - 260) / 2)
        #expect(origin.y == 1000 - 44 - 12)
    }

    // MARK: Voice gate — concise blocked reasons, never silent

    @Test func gateBlocksWhenModelMissingWithPlainReason() {
        guard case .blocked(let reason) = VoiceOverlayPolicy.gate(modelReady: false, micPermissionGranted: true)
        else {
            Issue.record("expected blocked")
            return
        }
        #expect(reason.contains("model"))
        #expect(reason.contains("type")) // always offers the typing alternative
    }

    @Test func gateBlocksWhenMicUnknownOrDenied() {
        // Not determined (never asked): 0.3.11 — the user's hold key or the
        // mic button is the reachable request action (official system
        // prompt from that intent); the copy points at the pop-up, not
        // System Settings (which does not list the app until asked).
        guard case .blocked(let notDetermined) = VoiceOverlayPolicy.gate(modelReady: true, micPermissionGranted: nil)
        else {
            Issue.record("expected blocked")
            return
        }
        #expect(notDetermined.lowercased().contains("microphone"))
        #expect(notDetermined.contains("Allow microphone access"))
        #expect(notDetermined.contains("next hold"))
        #expect(!notDetermined.contains("System Settings"))
        // Denied: System Settings is the right fix.
        guard case .blocked(let denied) = VoiceOverlayPolicy.gate(modelReady: true, micPermissionGranted: false)
        else {
            Issue.record("expected blocked")
            return
        }
        #expect(denied.contains("System Settings"))
        #expect(denied != notDetermined)
        // The hold-intent prompt flow reuses the SAME shared copy.
        #expect(VoiceOverlayPolicy.micDeniedCopy == denied)
        #expect(VoiceOverlayPolicy.micNotDeterminedCopy == notDetermined)
        #expect(VoiceOverlayPolicy.micGrantedNextHoldCopy.contains("hold again"))
    }

    @Test func gatePassesOnlyWhenModelAndMicReady() {
        #expect(VoiceOverlayPolicy.gate(modelReady: true, micPermissionGranted: true) == .ready)
    }

    // MARK: Accessibility mismatch — honest diagnosis, no TCC touch

    @Test func mismatchHintOnlyForInstalledUntrustedApp() {
        let hint = VoiceOverlayPolicy.accessibilityMismatchHint(trusted: false, bundlePath: "/Applications/QuikCal.app")
        #expect(hint != nil)
        // Honest wording (owner, 2026-11-06): AXIsProcessTrusted cannot
        // observe the actual Settings toggle, so the hint says "Permission
        // not detected" — never "switched off", and the entry story stays
        // conditional ("If"), not asserted fact.
        #expect(hint?.contains("Permission not detected") == true)
        #expect(hint?.contains("switched off") == false)
        // 2026-11-07 mismatch evidence (owner screenshot: System Settings
        // switch ON, app honestly untrusted — re-signed ad-hoc binary):
        // the hint must cover the switch-ALREADY-ON case with the two
        // standard regrant actions, still conditional, never asserting
        // the toggle state and never faking trust.
        #expect(hint?.contains("If QuikCal is already listed with its switch on") == true)
        #expect(hint?.contains("turn the switch off and on once") == true)
        #expect(hint?.contains("remove that entry") == true)
        #expect(hint?.contains("add this QuikCal again") == true)
        #expect(VoiceOverlayPolicy.accessibilityMismatchHint(trusted: true, bundlePath: "/Applications/QuikCal.app") == nil)
        // Developer / DMG copies get no mismatch claim — the guide's
        // install-first warning already covers them.
        #expect(VoiceOverlayPolicy.accessibilityMismatchHint(trusted: false, bundlePath: "/Users/example/Downloads/QuikCal.app") == nil)
    }
}
