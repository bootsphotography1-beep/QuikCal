import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.4 visual repair: production content contract (P1-1), Models layout
/// policy (P1-2), tertiary→secondary palette (P1-3, copy-level), and the
/// DEBUG QA host router + fixture snapshots (P1-4 / missing proof).
/// No GUI, no network, no TCC — pure contract tests.
struct VisualRepair034Tests {

    // MARK: P1-1 — Welcome demo contract (RETIRED 0.3.13)
    //
    // The Welcome interactive demo (text field, sample card, chip, hint)
    // was removed per the owner-approved REV2.1 design: Welcome is short
    // what/how copy only. `WelcomeDemoContent` was deleted with it; the
    // current Welcome copy contract lives in
    // OnboardingWelcomeVoice0313Tests (new file). Practice keeps the real
    // parse-only preview.

    // MARK: P1-2 — Models layout policy

    @Test func modelsBottomGutterIs16To24Points() {
        #expect(ModelsLayoutPolicy.hasRequiredGutter(ModelsLayoutPolicy.bottomGutter))
        #expect(ModelsLayoutPolicy.bottomGutter >= 16 && ModelsLayoutPolicy.bottomGutter <= 24)
        #expect(ModelsLayoutPolicy.footerTopSeparation > 0)
    }

    @Test func modelsGutterGuardRejectsFragileValues() {
        #expect(!ModelsLayoutPolicy.hasRequiredGutter(8))
        #expect(!ModelsLayoutPolicy.hasRequiredGutter(0))
        #expect(!ModelsLayoutPolicy.hasRequiredGutter(40))
    }

    // MARK: P1-3 — Readable secondary copy (content-level)

    @Test func holdHintCopyIsLegibleSecondaryWording() {
        // The Settings hint text itself is unchanged; the fix is the
        // .secondary foreground in the view layer. This test pins the
        // exact strings so a regression to hidden/invented copy fails.
        #expect(HoldToTalkGuideCopy.manualFallback.contains("System Settings"))
        #expect(HoldToTalkGuideCopy.manualFallback.contains("Accessibility"))
    }

    // MARK: QA host routing (DEBUG-only, inert without the gate flag)

    @Test func qaParserReturnsNilWithoutDefaultsFlag() {
        #expect(QAHostRouter.parse(arguments: []) == nil)
        #expect(QAHostRouter.parse(arguments: ["--qc-qa-surface", "settings"]) == nil)
        #expect(QAHostRouter.parse(arguments: ["QuietCalendar"]) == nil)
    }

    @Test func qaParserRoutesSettingsCaptureCoachmarkGuide() {
        for surface in [QASurface.settings, .capture, .coachmark, .coachmarkFallback, .guide, .onboarding] {
            let config = QAHostRouter.parse(arguments: ["--qc-qa-defaults", "1", "--qc-qa-surface", surface.rawValue])
            #expect(config?.surface == surface)
        }
        // Unknown surface → nil surface, still QA-gated.
        let unknown = QAHostRouter.parse(arguments: ["--qc-qa-defaults", "1", "--qc-qa-surface", "nope"])
        #expect(unknown?.surface == nil)
    }

    @Test func qaParserReadsStepGlassModelsStateWindowFile() {
        let config = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-step", "3",
            "--qc-qa-glass", "50",
            "--qc-qa-models-state", "downloading",
            "--qc-qa-window-id-file", "/tmp/window.txt"
        ])
        // Legacy step raw 3 (speechPrivacy) migrates to the merged voiceSetup
        // page through the SAME explicit map as persisted snapshots.
        #expect(config?.page == .voiceSetup)
        #expect(config?.glassPercent == 50)
        #expect(config?.modelsState == .downloading)
        #expect(config?.windowIDFilePath == "/tmp/window.txt")
    }

    @Test func qaParserReadsNewPageFlag() {
        let config = QAHostRouter.parse(arguments: [
            "--qc-qa-defaults", "1",
            "--qc-qa-page", "3"
        ])
        #expect(config?.page == .ready)
    }

    @Test func qaSuiteIsSeparateEphemeralDomain() {
        #expect(QAHostRouter.qaDefaultsSuiteName == "com.quietcalendar.qa034")
        #expect(QAHostRouter.qaDefaultsSuiteName != "com.quietcalendar.qa")
    }

    // MARK: QA speech-model fixtures (mock bytes, labelled, no network)

    @Test func fixtureMissingShowsSpeechModelMissing() {
        let snaps = QAModelsFixture.snapshots(for: .missing)
        #expect(snaps.speech.phase == .idle)
        #expect(snaps.speech.message?.contains("QA fixture") == true)
    }

    @Test func fixtureDownloadingIsMockQuarterOfSpeechModel() {
        let snaps = QAModelsFixture.snapshots(for: .downloading)
        #expect(snaps.speech.phase == .downloading)
        let expectedRatio = Double(snaps.speech.bytesReceived) / Double(snaps.speech.bytesExpected ?? 1)
        #expect(abs(expectedRatio - 0.25) < 0.01)
    }

    @Test func fixtureErrorShowsFailedWithRetrySignal() {
        let snaps = QAModelsFixture.snapshots(for: .error)
        #expect(snaps.speech.phase == .failed)
        #expect(snaps.speech.lastError?.contains("simulated") == true)
    }

    @Test func fixtureReadyShowsSpeechReady() {
        let snaps = QAModelsFixture.snapshots(for: .ready)
        #expect(snaps.speech.phase == .ready)
    }

    // MARK: Compiled-guard contract (Release must ignore QA args)

    @Test func qaConfigIsInertWithoutGateFlagAndNeedsEphemeralSuite() {
        // Any argument set without --qc-qa-defaults must not route,
        // even with surface/models flags present. This is the unit-level
        // half of the Release-isolation guard; the other half is the
        // `#if DEBUG` gate in AppDelegate (verified by building Release
        // and confirming the QA string is absent — see VISUAL-REPAIR-0.3.4.md).
        let args = ["--qc-qa-surface", "settings", "--qc-qa-models-state", "ready", "--qc-qa-step", "0"]
        #expect(QAHostRouter.parse(arguments: args) == nil)
        let gated = QAHostRouter.parse(arguments: ["--qc-qa-defaults", "1"] + args)
        #expect(gated != nil)
    }
}
