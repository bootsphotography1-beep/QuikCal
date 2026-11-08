import Foundation
import Testing
@testable import QuietCalendarCore

struct FoundationModelsPhraseRuntimeTests {
    private struct StubGenerator: FoundationModelsPhraseGenerating {
        let readiness: FoundationModelsReadiness
        let response: FoundationModelsPhraseResponse
        let shouldFail: Bool

        func generate(transcript: String, now: Date, calendar: Calendar) async throws -> FoundationModelsPhraseResponse {
            if shouldFail { throw StubFailure.generation }
            return response
        }
    }

    private enum StubFailure: Error { case generation }

    @Test func typedAdapterMapsEveryPhraseField() {
        let event = FoundationModelsPhraseEvent(
            title: "Budget review",
            datePhrase: "next Wednesday",
            timePhrase: "three o'clock in the afternoon",
            durationPhrase: "45 minutes",
            location: "Room 4",
            reminderPhrase: "15 minutes before",
            notes: "bring the printed plan")

        let raw = FoundationModelsPhraseResponse(events: [event]).rawPhraseOutput
        #expect(raw.events == [RawPhraseEvent(
            title: "Budget review",
            datePhrase: "next Wednesday",
            timePhrase: "three o'clock in the afternoon",
            durationPhrase: "45 minutes",
            location: "Room 4",
            reminderPhrase: "15 minutes before",
            notes: "bring the printed plan")])
    }

    @Test func typedOutputStillUsesSchemaLimits() async {
        let longTitle = String(repeating: "x", count: ExtractionSchemaV2.maxFieldLengths["title"]! + 1)
        let generator = StubGenerator(
            readiness: .available,
            response: FoundationModelsPhraseResponse(events: [FoundationModelsPhraseEvent(title: longTitle)]),
            shouldFail: false)
        let runtime = FoundationModelsPhraseRuntime(generator: generator)

        do {
            _ = try await runtime.extract(transcript: longTitle, now: Date(), calendar: .current)
            Issue.record("oversized typed output must be rejected")
        } catch let error as ExtractionRuntimeError {
            guard case .invalidOutput = error else {
                Issue.record("expected schema rejection, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func unavailableAndGenerationErrorsAreExplicit() async {
        let unavailable = FoundationModelsPhraseRuntime(generator: StubGenerator(
            readiness: .appleIntelligenceNotEnabled,
            response: FoundationModelsPhraseResponse(events: []),
            shouldFail: false))
        do {
            _ = try await unavailable.extract(transcript: "synthetic", now: Date(), calendar: .current)
            Issue.record("unavailable runtime must not generate")
        } catch let error as ExtractionRuntimeError {
            guard case .unavailable = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let failing = FoundationModelsPhraseRuntime(generator: StubGenerator(
            readiness: .available,
            response: FoundationModelsPhraseResponse(events: []),
            shouldFail: true))
        do {
            _ = try await failing.extract(transcript: "synthetic", now: Date(), calendar: .current)
            Issue.record("generation failure must be surfaced")
        } catch let error as ExtractionRuntimeError {
            #expect(error == .generationFailed)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func pipelineKeepsGroundingAndConfirmationValidation() async {
        let generator = StubGenerator(
            readiness: .available,
            response: FoundationModelsPhraseResponse(events: [FoundationModelsPhraseEvent(
                title: "Secret meeting",
                datePhrase: "tomorrow",
                timePhrase: "2pm")]),
            shouldFail: false)
        let runtime = FoundationModelsPhraseRuntime(generator: generator)
        let pipeline = PhrasePipeline(phraseRuntime: runtime, calendar: .current)
        let outcome = await pipeline.run(transcript: "Lunch tomorrow at 2pm", now: Date())

        #expect(outcome.source == .appleFoundationModels)
        guard case .drafts(let drafts, _) = outcome.set, let draft = drafts.first else {
            Issue.record("expected a confirmation draft")
            return
        }
        #expect(draft.title.isEmpty || draft.issues.contains(where: { $0.blocking }))
        #expect(!draft.canAdd)
    }

    @Test func productionPipelineDefaultsToAppleRuntime() {
        let pipeline = PhrasePipeline(calendar: .current)
        #expect(pipeline.phraseRuntime?.runtimeName == "Apple Foundation Models (on-device)")
        #expect(OnboardingPage.flowOrder == [.welcome, .calendar, .axPermission, .voiceSetup, .ready])
        #expect(FoundationModelsReadiness.appleIntelligenceNotEnabled.onboardingSummary.contains("System Settings"))
        #expect(FoundationModelsReadiness.available.onboardingSummary.contains("review every draft"))
    }

    @Test func legacyPreferenceAndUserFacingQwenOptionsAreIgnored() throws {
        let suite = "quietcalendar.apple-runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "quietCalendar.preferLocalModelAssist")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appPreferences = try String(contentsOf: root.appendingPathComponent("Sources/QuietCalendarCore/AppPreferences.swift"), encoding: .utf8)
        let viewModel = try String(contentsOf: root.appendingPathComponent("Sources/QuietCalendar/ViewModel.swift"), encoding: .utf8)
        let onboarding = try String(contentsOf: root.appendingPathComponent("Sources/QuietCalendar/OnboardingWindowController.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/QuietCalendar/SettingsWindowController.swift"), encoding: .utf8)

        #expect(!appPreferences.contains("preferLocalModelAssist"))
        #expect(!viewModel.contains("preferLocalModel"))
        #expect(viewModel.contains("PhrasePipeline(calendar: calendar)"))
        #expect(onboarding.contains("foundationModelsReadinessRow"))
        #expect(onboarding.contains("startSpeechInstall()"))
        #expect(!onboarding.lowercased().contains("qwen"))
        #expect(!settings.lowercased().contains("qwen"))
        #expect(!settings.lowercased().contains("ollama"))
    }

    @Test(.enabled(if: FoundationModelsReadiness.current.isAvailable, "Apple Foundation Models are unavailable on this host"))
    func actualAppleSyntheticSmokeWhenSystemIsReady() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let raw = try await FoundationModelsPhraseRuntime().extract(
            transcript: "Synthetic project sync tomorrow at 2 pm in Room 4",
            now: Date(),
            calendar: calendar)
        #expect(!raw.events.isEmpty)
        let validated = PhraseValidator.validate(raw, transcript: "Synthetic project sync tomorrow at 2 pm in Room 4")
        #expect(validated.count == raw.events.count)
    }
}
