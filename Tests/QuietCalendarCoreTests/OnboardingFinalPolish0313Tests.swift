import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 final bounded polish — focused copy contracts for the four
/// parent visual corrections (pure logic; the rendered PNGs are the
/// parent's visual gate):
///   1. Ready page: ONE instruction naming the ACTUAL selected hold key,
///      no owner-banned "Experimental AI" boilerplate, no filler chips;
///      skipped voice setup stays honest (typing works, hold unclaimed).
///   2. Inline permission checkpoint copies differ by REAL state:
///      AX-untrusted vs trusted-but-listener-not-installed (covered in
///      GoogleLocalConfigStartupRepairTests; pinned here too so the pair
///      cannot regress silently).
///   3. Open Settings one-line layout is a view-layer fix — verified by
///      the captured PNG geometry (packaging/FINAL_POLISH.md).
///   4. No-correction hint: the editable field is ABOVE the status line,
///      so the copy never claims "below"; the actual shortcut is named.
struct OnboardingFinalPolish0313Tests {

    // MARK: Fix 1 — Ready-page completion copy

    @Test func readyInstructionUsesActualSelectedKey() {
        let copy = OnboardingCompletionCopy.instruction(
            voiceSetupSkipped: false, shortcutName: "Fn")
        #expect(copy == "Hold Fn to speak, or click the menu bar icon to type.")
        // Not always Fn — the ACTUAL selected key is interpolated.
        let globe = OnboardingCompletionCopy.instruction(
            voiceSetupSkipped: false, shortcutName: "Globe")
        #expect(globe.contains("Globe"))
        #expect(!globe.contains("Fn"))
    }

    @Test func readyCopyNeverCarriesBannedBoilerplate() {
        for skipped in [false, true] {
            let copy = OnboardingCompletionCopy.instruction(
                voiceSetupSkipped: skipped, shortcutName: "Fn")
            #expect(!copy.contains("Experimental"))
            #expect(!copy.lowercased().contains("ai"))
        }
    }

    @Test func skippedVoiceSetupStaysHonest() {
        let copy = OnboardingCompletionCopy.instruction(
            voiceSetupSkipped: true, shortcutName: "Fn")
        // Typing still possible, clearly messaged…
        #expect(copy.contains("type"))
        // …and hold-to-talk is NOT claimed ready (skipped honesty).
        #expect(copy.contains("skipped"))
        #expect(!copy.contains("Hold Fn to speak"))
    }

    @Test func readinessSummaryOnlyWhenSomethingIsNotReady() {
        // All ready → NO summary line, no badges, no filler.
        #expect(OnboardingCompletionCopy.readinessSummary(
            isTransferring: false, speechModelReady: true) == nil)
        // Transferring → honest progress pointer.
        let transferring = OnboardingCompletionCopy.readinessSummary(
            isTransferring: true, speechModelReady: false)
        #expect(transferring?.contains("downloading") == true)
        // Pending → honest "type now, download later".
        let pending = OnboardingCompletionCopy.readinessSummary(
            isTransferring: false, speechModelReady: false)
        #expect(pending?.contains("type now") == true)
    }

    // MARK: Fix 2 — inline permission checkpoint copies (state-distinct)

    @Test func practiceCopyDistinguishesUntrustedFromListenerNotReady() {
        let untrusted = PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: false, listenerInstalled: false,
            accessibilityTrusted: false, shortcutName: "Fn")
        let trustedNoListener = PracticeDetectionPolicy.practiceStatusText(
            phase: .idle, releaseDetected: false, listenerInstalled: false,
            accessibilityTrusted: true, shortcutName: "Fn")
        // Distinct copies for distinct states — never one generic ask.
        #expect(untrusted != trustedNoListener)
        #expect(untrusted.contains("Accessibility above"))
        #expect(trustedNoListener.contains("hold-to-talk"))
        // Neither re-asks for a grant in the wrong state.
        #expect(!trustedNoListener.contains("Accessibility"))
        #expect(!untrusted.contains("hold-to-talk, then"))
    }

    // MARK: Fix 4 — No-correction hint accuracy

    @Test func noHintNeverClaimsBelowAndNamesActualKey() {
        let outcome = ConfirmationRejectionPolicy.reject(
            transcript: "Lunch with Ana tomorrow at noon",
            shortcutName: "Globe")
        #expect(outcome.hint == "Not added. Edit your text, or hold Globe to speak again.")
        #expect(!outcome.hint.contains("below"))
        #expect(!outcome.hint.contains("Above"))
        #expect(outcome.restoredTranscript == "Lunch with Ana tomorrow at noon")
    }

    @Test func noHintEmptyTranscriptStillHonestAndDirectionFree() {
        let outcome = ConfirmationRejectionPolicy.reject(transcript: "  ", shortcutName: "Fn")
        #expect(outcome.hint == "Not added. Hold Fn to speak, or type your note.")
        #expect(!outcome.hint.contains("below"))
        #expect(outcome.restoredTranscript.isEmpty)
    }
}
