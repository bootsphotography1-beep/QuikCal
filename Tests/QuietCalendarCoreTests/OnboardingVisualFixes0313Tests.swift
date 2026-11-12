import Testing
import Foundation
@testable import QuietCalendarCore

// MARK: - 0.3.13 final targeted visual correction pass (2026-11-07)
//
// Parent visual review found real mismatches between the approved Figma
// (file tY2iozklxsV37zSXwFO5WX — 6:14/6:41/6:122/6:211/7:95) and the built
// app. These tests pin the CORRECTED contracts at two levels:
//   1. pure policy values (colors, fixture-status consistency);
//   2. source-policy contracts on the production view file
//      (`Sources/QuietCalendar/OnboardingWindowController.swift`) so the
//      banned prose/styles cannot silently return.

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/QuietCalendarCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // package root
}

private func onboardingControllerSource() throws -> String {
    let url = packageRoot()
        .appendingPathComponent("Sources/QuietCalendar/OnboardingWindowController.swift")
    return try String(contentsOfFile: url.path, encoding: .utf8)
}

private func sharedButtonStyleSource() throws -> String {
    let url = packageRoot()
        .appendingPathComponent("Sources/QuietCalendar/QuietUI.swift")
    return try String(contentsOfFile: url.path, encoding: .utf8)
}

/// Collapses all whitespace runs to single spaces so pins survive reformatting.
private func normalized(_ source: String) -> String {
    source
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

// WCAG 2.x relative luminance + contrast ratio.
private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
    func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}

private func contrastRatio(
    _ a: (red: Double, green: Double, blue: Double),
    _ b: (red: Double, green: Double, blue: Double)
) -> Double {
    let la = relativeLuminance(red: a.red, green: a.green, blue: a.blue)
    let lb = relativeLuminance(red: b.red, green: b.green, blue: b.blue)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

struct OnboardingVisualFixes0313Tests {

    // MARK: - F1: solid system root backgrounds

    @Test func rootBackgroundIsSolidWhiteLightAnd1E1E1EDark() {
        // Owner rule + design frames (all `bg-white` light): the onboarding
        // root is SOLID — #FFFFFF light, #1E1E1E dark — never a pale sage
        // gradient. Gradient lives ONLY inside the glass sample tiles.
        #expect(OnboardingVoiceVisualPolicy.rootBackgroundLightRGB == (red: 1.0, green: 1.0, blue: 1.0))
        #expect(OnboardingVoiceVisualPolicy.rootBackgroundDarkRGB
            == (red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0))
    }

    @Test func onboardingControllerPaintsTheApprovedTokenRootAndNoGradient() throws {
        let source = try onboardingControllerSource()
        let flat = normalized(source)
        // 2026-11-12 approved redesign: the root paints the shared
        // `QuietDesign.Color.background(colorScheme)` token (sampled from
        // the approved screens: #F8FAF9 light / #202423 dark), never a
        // gradient and never the retired solid #FFFFFF/#1E1E1E policy pair.
        #expect(flat.contains("QuietDesign.Color.background(colorScheme)"))
        // …and the old full-window gradient/atmosphere overlays are gone.
        #expect(!source.contains("RadialGradient"))
        #expect(!flat.contains("blendMode(.plusLighter)"))
        #expect(!flat.contains("OnboardingVoiceVisualPolicy.rootBackgroundLightRGB"))
        #expect(!flat.contains("OnboardingVoiceVisualPolicy.rootBackgroundDarkRGB"))
    }

    // MARK: - F4: deep-sage primary fill (AA contrast)

    @Test func primaryFillIsDeepSage4E7A62() {
        let rgb = OnboardingVoiceVisualPolicy.primaryFillRGB
        #expect(rgb == (red: 78.0 / 255.0, green: 122.0 / 255.0, blue: 98.0 / 255.0))
    }

    @Test func whiteOnPrimaryFillIsAAButWhiteOnLightSageIsNot() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let deepSage = OnboardingVoiceVisualPolicy.primaryFillRGB
        let lightSage = (red: 0.45, green: 0.62, blue: 0.52) // #739e85 accent
        // White 15 pt medium text on the primary fill clears AA…
        #expect(contrastRatio(white, deepSage) >= 4.5)
        // …while the old lighter sage fill did not (≈3:1) — the documented
        // reason it is now accent/rings only, never a white-text fill.
        #expect(contrastRatio(white, lightSage) < 4.5)
    }

    @Test func primaryButtonStyleUsesDeepSageFillWithDistinctDisabledState() throws {
        let source = try sharedButtonStyleSource()
        let flat = normalized(source)
        // The shared QuietUI primary style fills with the deep sage…
        #expect(flat.contains("QuietPalette.primaryFill.opacity(configuration.isPressed ? 0.75 : 1)"))
        // …with a visually distinct disabled fill…
        #expect(flat.contains("QuietPalette.primaryFill.opacity(0.35)"))
        // …and the old light-sage fill is gone from the primary style.
        #expect(!flat.contains("QuietPalette.accent.opacity(configuration.isPressed ? 0.75 : 1)"))
    }

    // MARK: - F2: models page — no duplicate heading, no slab, no banned prose

    @Test func voiceSetupPageMergesModelsPermissionPracticeOnOnePage() throws {
        let source = try onboardingControllerSource()
        let flat = normalized(source)
        // Compact 4-page flow (2026-11-07 review pass): the merged Voice
        // setup page is ONE scene — ONE compact voice-model row + ONE
        // concise accessibility permission row + real Fn practice —
        // replacing the retired Speech-model / Practice pages and the
        // 2026-11-07 builder's tall modelPackPanel stack (parent visual
        // finding A: no model-name rows, no repeated Ready badges, grant
        // steps under disclosure).
        #expect(flat.contains("sceneTitle( \"Try a quick hold.\","))
        #expect(flat.contains("voiceModelRow"))
        #expect(flat.contains("voiceAccessibilityRow"))
        #expect(flat.contains("FnKeyCapView("))
        // The old tall panel is gone from the merged page.
        #expect(!flat.contains("modelPackPanel"))
        // No duplicate scene headings for the retired pages.
        #expect(!flat.contains("sceneTitle( \"Speech model\","))
        #expect(!flat.contains("sceneTitle( \"Models\","))
        #expect(!flat.contains("sceneTitle( \"Practice\","))
    }

    @Test func bannedModelProseIsAbsentFromProductionSource() throws {
        let source = try onboardingControllerSource()
        // Owner-removed prose must not return to the live onboarding UI.
        #expect(!source.contains("Your audio and text stay on your Mac."))
        #expect(!source.contains("Imports the Cloud Console"))
    }

    @Test func modelRowsRenderDirectlyOnCanvasWithoutDecorativeSlab() throws {
        let source = try onboardingControllerSource()
        // 2026-11-07 review pass: the old two-row modelPackPanel section
        // ("Two tidy rows" + hairline divider inside a padded slab) is
        // RETIRED with the panel itself (parent visual finding A — one
        // compact "Voice ready" row, no model-name stack). Equivalent
        // coverage for the new structure: the compact row exists, the old
        // slab markers are gone, and no divider-separated model-pair
        // section remains.
        #expect(source.contains("voiceModelRow"))
        #expect(!source.contains("Two tidy rows"))
        #expect(!source.contains("modelPackPanel"))
    }

    // MARK: - F3: practice page fits the footer; diagnostics is a small link

    @Test func practiceHoldCompactsItsTopSpacer() throws {
        let source = try onboardingControllerSource()
        let flat = normalized(source)
        // practiceHold shares the compact spacer so the whole practice
        // content fits 640×600 with the footer chrome visible.
        #expect(flat.contains(
            "Spacer(minLength: session.holdGuide.phase == .openSettings || session.holdGuide.phase == .practiceHold ? 8 : 60)"
        ))
    }

    @Test func copyShortcutDiagnosticsIsAQuietLinkNotAPill() throws {
        let source = try onboardingControllerSource()
        guard let start = source.range(of: "copyShortcutDiagnosticsButton: some View {")
        else {
            Issue.record("copyShortcutDiagnosticsButton not found")
            return
        }
        let section = String(source[start.upperBound...].prefix(700))
        #expect(section.contains("QuietTextButtonStyle"))
        #expect(!section.contains("QuietSecondaryButtonStyle"))
    }

    #if DEBUG
    @Test func qaFixtureStatusPairsConsistentlyWithHeldAndNeutralCaps() {
        // Held/neutral fixtures pair with a simulated TRUSTED monitor's
        // status (labelled in-frame) — never a contradictory
        // "detection is not active" warning next to a held-red cap.
        #expect(OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: .holding)
            == "Holding… release to preview.")
        #expect(OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: .neutral)
            == "Waiting for a hold…")
        // Unavailable / released / production keep the REAL honest status.
        #expect(OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: .unavailable) == nil)
        #expect(OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: .released) == nil)
        #expect(OnboardingVoiceVisualPolicy.qaPracticeStatusOverride(fixture: nil) == nil)
    }
    #endif

    // MARK: - F5: Google signed-out — no duplicated subtitle, no explainer

    @Test func googleOptionRowUsesTheApprovedRedesignCopy() throws {
        let source = try onboardingControllerSource()
        // 2026-11-12 approved redesign: the Google destination row reads
        // "Google Calendar — Connect your Google account."; the onboarding
        // view no longer references the retired "Sign in to connect your
        // calendar." copy anywhere.
        #expect(source.contains("Connect your Google account."))
        #expect(!source.contains("OnboardingGoogleCopy.subtitle"))
        // And the copy itself is unchanged (pinned since 0.3.12).
        #expect(OnboardingGoogleCopy.subtitle == "Sign in to connect your calendar.")
    }

    @Test func googleImportExplainerIsRemovedFromSignedOutUI() throws {
        let source = try onboardingControllerSource()
        // The technical import prose is gone from the regular signed-out
        // UI; the link itself (label + accessible name) remains, and the
        // detailed guidance lives in Settings / the file picker message.
        #expect(!source.contains("Imports the Cloud Console"))
        #expect(source.contains("importLinkLabel"))
        #expect(source.contains("importAccessibilityLabel"))
    }
}
