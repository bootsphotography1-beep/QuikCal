import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 onboarding visual pass (owner-approved Figma REV2.1): Welcome
/// copy contract, glass comparison tiles, practice key states, Google
/// signed-out copy, and the practice delete-phrase refusal. Pure policy
/// tests — no GUI, no network, no TCC.
struct OnboardingWelcomeVoice0313Tests {

    // MARK: - Welcome (design 6:14 / 7:251): short what/how only

    @Test func welcomeCopyIsTheApprovedShortWhatHow() {
        #expect(OnboardingVoiceVisualPolicy.WelcomeCopy.brand == "QuikCal")
        #expect(OnboardingVoiceVisualPolicy.WelcomeCopy.headline == "Speak to manage your calendar.")
        #expect(OnboardingVoiceVisualPolicy.WelcomeCopy.how == "Hold Fn to add or delete an event. Review it, then confirm.")
    }

    @Test func welcomeCopyMakesNoUnimplementedClaim() {
        // Delete is implemented in this build (explicit-confirm flow), so
        // the "add or delete" claim is truthful. The copy must NOT claim
        // anything the app can't do: no "automatically deleted", no
        // "without confirmation".
        let how = OnboardingVoiceVisualPolicy.WelcomeCopy.how
        #expect(how.contains("Review it, then confirm."))
        #expect(!how.lowercased().contains("automatic"))
    }

    // MARK: - Voice-bar glass (2026-11-07 owner revision — tiles removed)
    //
    // The 0.3.13 Low/Current/High comparison tiles (barAlpha / barBlur /
    // tileLabel / GlassComparisonKind) were REMOVED per the owner's
    // one-preview revision — including the tile blur that blurred the
    // pill's TEXT (the "blurred bar letters" the owner reported). Their
    // pins were replaced by the full VoiceBarGlassPolicy suite in
    // FnGlassTransitionFixTests.swift.

    // MARK: - Practice key states (design 24:46–24:53; real monitor only)

    @Test func practiceKeyStateDerivesOnlyFromRealMonitorState() {
        #expect(OnboardingVoiceVisualPolicy.practiceKeyState(phase: .idle, listenerInstalled: true) == .neutral)
        #expect(OnboardingVoiceVisualPolicy.practiceKeyState(phase: .holding, listenerInstalled: true) == .holding)
        #expect(OnboardingVoiceVisualPolicy.practiceKeyState(phase: .releasing, listenerInstalled: true) == .neutral)
        // Detection not installed → honest unavailable, never a faked hold.
        #expect(OnboardingVoiceVisualPolicy.practiceKeyState(phase: .holding, listenerInstalled: false) == .unavailable)
        #expect(OnboardingVoiceVisualPolicy.practiceKeyState(phase: .idle, listenerInstalled: false) == .unavailable)
    }

    @Test func heldKeyLiftsRedUnlessReduceMotion() {
        // Held: red with lift…
        #expect(OnboardingVoiceVisualPolicy.keyIsRed(state: .holding))
        #expect(OnboardingVoiceVisualPolicy.keyLiftOffset(state: .holding, reduceMotion: false) == -6)
        // …Reduce Motion: no movement, red still carries the state.
        #expect(OnboardingVoiceVisualPolicy.keyLiftOffset(state: .holding, reduceMotion: true) == 0)
        #expect(OnboardingVoiceVisualPolicy.keyIsRed(state: .holding))
        // Settled/neutral/unavailable: no red, no lift.
        #expect(!OnboardingVoiceVisualPolicy.keyIsRed(state: .neutral))
        #expect(OnboardingVoiceVisualPolicy.keyLiftOffset(state: .neutral, reduceMotion: false) == 0)
        #expect(!OnboardingVoiceVisualPolicy.keyIsRed(state: .unavailable))
    }

    // MARK: - Google signed-out (design 6:122 / 24:45 / 6:147)

    @Test func googleSignedOutImportLinkCopyIsTinyButAccessible() {
        #expect(OnboardingVoiceVisualPolicy.GoogleSignedOutCopy.importLinkLabel == "Import Google configuration…")
        #expect(OnboardingVoiceVisualPolicy.GoogleSignedOutCopy.importAccessibilityLabel == "Import Google configuration")
        // 0.3.13 final pass (parent visual review): the technical
        // "Imports the Cloud Console … Keychain" explainer was REMOVED
        // from the regular signed-out UI (and from this policy) — the
        // detailed guidance lives in Settings and the file picker's own
        // message. The removal itself is pinned by
        // OnboardingVisualFixes0313Tests (source-scan).
    }

    // MARK: - Practice refuses delete phrasing (parse-only, honest)

    @Test func practiceRefusesDeletePhrasingWithoutLookup() {
        #expect(DeleteFlowCopy.practiceRefusal.contains("Practice previews adds only"))
        #expect(DeleteFlowCopy.practiceRefusal.contains("nothing is deleted"))
    }

    // MARK: - Voice pill placement preserved (requirement: verify + keep)

    @Test func pillOriginStaysTopCenterOfVisibleFrame() {
        // 260×44 pill, 12 pt below the top of a 1512×982 visible frame.
        let origin = VoiceOverlayPolicy.pillOrigin(
            visibleFrameMinX: 0, visibleFrameMinY: 0,
            visibleFrameWidth: 1512, visibleFrameHeight: 982,
            pillWidth: 260, pillHeight: 44, topInset: 12)
        #expect(origin.x == (1512 - 260) / 2)
        #expect(origin.y == 982 - 44 - 12)
    }
}
