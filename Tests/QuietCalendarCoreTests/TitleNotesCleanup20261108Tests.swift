import Testing
import Foundation
@testable import QuietCalendarCore

// 0.3.20 saved-view title/notes cleanup regression tests.
//
// Covers the 0.3.20 fixes:
// 1. Deterministic parser: conversational command wrapper ("go ahead and
//    add my …") and cue-attached scheduling phrases ("due morning") leave
//    the title; the subject keeps its own words; no invented start time.
// 2. Shared normalizer on the MODEL path: the same cleanup applies to
//    model-extracted titles/notes at the structured extraction boundary.
// 3. Notes keep only useful user context; correction scaffolding
//    ("9 a.m. instead of") is dropped; explicit titles survive verbatim.

@Suite
struct TitleNotesCleanup20261108Tests {
    private let now = Date(timeIntervalSince1970: 1_793_880_000) // fixed reference

    private func intent(_ text: String) -> EventIntent? {
        switch EventParser().extractIntent(text, now: now) {
        case .intent(let intent): return intent
        default: return nil
        }
    }

    // MARK: - Deterministic path (owner example)

    @Test func goAheadAddMyHomeworkBecomesConciseSubject() {
        // Owner example: "Go ahead and add my Japanese homework due morning"
        // → title "Japanese homework". "due morning" is scheduling context:
        // it must NOT become an invented clock time (time stays nil → the
        // resolver's honest no-time ask applies).
        let parsed = intent("Go ahead and add my Japanese homework due morning")
        #expect(parsed != nil)
        #expect(parsed?.title == "Japanese homework")
        #expect(parsed?.notes == nil)
        #expect(parsed?.time == nil)
        #expect(parsed?.date == nil)
    }

    @Test func dueTomorrowLeavesNoDanglingDue() {
        let parsed = intent("add my Japanese homework due tomorrow at 9am")
        #expect(parsed?.title == "Japanese homework")
        #expect(parsed?.date != nil)
        #expect(parsed?.time != nil)
    }

    @Test func dateAttachedTimeOfDayLeavesTitle() {
        // "tomorrow morning" — the day part is consumed with the date
        // phrase; the clock 9am still parses; nothing lands in the title.
        let parsed = intent("dentist tomorrow morning at 9am")
        #expect(parsed?.title == "Dentist")
        #expect(parsed?.date != nil)
        #expect(parsed?.time != nil)
    }

    @Test func cuelessTimeOfDayWordsKeepMeaningfulNames() {
        // No scheduling cue → the user's own wording survives.
        #expect(intent("movie night tomorrow at 8pm")?.title == "Movie night")
        #expect(intent("morning run tomorrow at 7am")?.title == "Morning run")
        #expect(intent("add an event called Morning Pages tomorrow at 9am")?.title == "Morning Pages")
    }

    @Test func possessiveMyOnlyStripsAsCommandWrapper() {
        // "my" after the command verb is the wrapper; "my" inside the
        // activity is meaningful content and stays.
        #expect(intent("schedule my dentist appointment tomorrow at 2pm")?.title == "Dentist appointment")
        #expect(intent("please remind me to water my plants tomorrow at 5pm")?.title == "Water my plants")
    }

    @Test func noTimeStillAsksHonestly() {
        // "due morning" must NEVER invent a calendar start.
        let resolved = EventParser().parse("Go ahead and add my Japanese homework due morning", now: now)
        guard case .needsClarification = resolved else {
            Issue.record("expected an honest no-clock-time clarification, got \(resolved)")
            return
        }
    }

    // MARK: - Shared normalizer (model path, structured extraction boundary)

    @Test func modelTitleStrippedToSubject() {
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            "Go ahead and add my Japanese homework due morning",
            transcript: "Go ahead and add my Japanese homework due morning")
        #expect(cleaned == "Japanese homework")
    }

    @Test func modelTitleExplicitCalledNamePreservedVerbatim() {
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            "morning pages",
            transcript: "add an event called Morning Pages tomorrow at 9am")
        #expect(cleaned == "morning pages") // user's intentional text, verbatim
    }

    @Test func modelTitleCalledNameSurvivesMultipleSchedulingTailsAndMixedCase() {
        let modelTitle = "mORNING pAGES"
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            modelTitle,
            transcript: "add an event called Morning Pages tomorrow at 9am on Tuesday")
        #expect(cleaned == modelTitle)
    }

    @Test func modelTitleQuotedNamePreservedVerbatim() {
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            "q3 REVIEW",
            transcript: "please add “Q3 review” tomorrow at 3pm")
        #expect(cleaned == "q3 REVIEW")
    }

    @Test func modelTitleCleaningToEmptyReturnsNil() {
        // Pure command wrapper with no subject → nil → the validator's
        // honest "What is this event called?" ask — never a hallucination.
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            "go ahead and add please",
            transcript: "go ahead and add please")
        #expect(cleaned == nil)
    }

    @Test func modelNotesCorrectionScaffoldingDropped() {
        // The owner-reported fragment: "9 a.m. instead of" is correction
        // scaffolding, not event context. The missing correction target is
        // never inferred — date/time fields are untouched by this cleanup.
        let cleaned = TitleNotesNormalizer.normalizedModelNotes(
            "9 a.m. instead of",
            transcript: "go ahead and add my Japanese homework due morning, 9 a.m. instead of",
            cleanedTitle: "Japanese homework")
        #expect(cleaned == nil)
    }

    @Test func modelNotesUsefulDetailKept() {
        // Real user detail (even with "instead of" but no clock token)
        // survives; scaffolding clauses are dropped clause-by-clause.
        let cleaned = TitleNotesNormalizer.normalizedModelNotes(
            "bring the report instead of the slides, 9 a.m. instead of",
            transcript: "board sync tomorrow at 9am, bring the report instead of the slides, 9 a.m. instead of",
            cleanedTitle: "Board sync")
        #expect(cleaned == "Bring the report instead of the slides")
    }

    @Test func modelNotesRawRequestDumpDropped() {
        // A notes value that merely duplicates the cleaned title is a raw
        // request dump, not event context.
        let cleaned = TitleNotesNormalizer.normalizedModelNotes(
            "go ahead and add my Japanese homework",
            transcript: "go ahead and add my Japanese homework due morning",
            cleanedTitle: "Japanese homework")
        #expect(cleaned == nil)
    }

    @Test func normalizeWholeModelOutput() throws {
        let output = try ExtractionSchemaV2.decode(
            #"{"events":[{"title":"Go ahead and add my Japanese homework due morning","date_phrase":null,"time_phrase":"9 a.m.","duration_phrase":null,"location":null,"reminder_phrase":"30 minutes before","notes":"9 a.m. instead of"}]}"#
        )
        let normalized = TitleNotesNormalizer.normalize(
            output, transcript: "Go ahead and add my Japanese homework due morning, remind me 30 minutes before, 9 a.m. instead of")
        #expect(normalized.events.first?.title == "Japanese homework")
        #expect(normalized.events.first?.notes == nil)
        #expect(normalized.events.first?.reminderPhrase == "30 minutes before")
        #expect(normalized.events.first?.timePhrase == "9 a.m.")
    }

    @Test func cleanedModelTitleStaysGrounded() {
        // Cleanup only removes tokens, so the cleaned title must still
        // trace to the user's own words (validator grounding).
        let transcript = "Go ahead and add my Japanese homework due morning"
        let cleaned = TitleNotesNormalizer.normalizedModelTitle(
            "Go ahead and add my Japanese homework due morning", transcript: transcript)
        #expect(cleaned == "Japanese homework")
        #expect(PhraseValidator.isGrounded(cleaned ?? "", in: transcript))
    }

    // MARK: - Phrase pipeline integration (model + fallback)

    @Test func phrasePipelineModelPathProducesCleanTitle() async {
        let runtime = StaticPhraseRuntime(
            result: #"{"events":[{"title":"Go ahead and add my Japanese homework due morning","date_phrase":"tomorrow","time_phrase":"9 a.m.","duration_phrase":null,"location":null,"reminder_phrase":"30 minutes before","notes":"9 a.m. instead of"}]}"#)
        let pipeline = PhrasePipeline(phraseRuntime: runtime, calendar: Calendar.current)
        let outcome = await pipeline.run(
            transcript: "Go ahead and add my Japanese homework due morning, remind me 30 minutes before, 9 a.m. instead of",
            now: now)
        guard case .drafts(let drafts, _) = outcome.set, let draft = drafts.first else {
            Issue.record("expected a drafts set"); return
        }
        #expect(draft.title == "Japanese homework")
        #expect(draft.notes == nil)
        #expect(draft.reminderLeadMinutes == 30)
    }

    @Test func phrasePipelineFallbackPathAlsoClean() async {
        // Deterministic fallback (model unavailable) gets the SAME cleanup
        // through the shared parser.
        let pipeline = PhrasePipeline(phraseRuntime: UnavailablePhraseRuntime(), calendar: Calendar.current)
        let outcome = await pipeline.run(
            transcript: "Go ahead and add my Japanese homework due morning",
            now: now)
        guard case .clarification = outcome.set else {
            // No clock time stated → honest ask; the fallback note labels it.
            Issue.record("expected honest no-time clarification"); return
        }
    }
}

/// Test double returning a frozen model response.
private struct StaticPhraseRuntime: PhraseExtractionRuntime {
    let runtimeName = "static-test"
    let result: String
    func extract(transcript: String, now: Date, calendar: Calendar) async throws -> RawPhraseOutput {
        try ExtractionSchemaV2.decode(result)
    }
}

/// Test double that is never reachable (forces the deterministic fallback).
private struct UnavailablePhraseRuntime: PhraseExtractionRuntime {
    let runtimeName = "unavailable-test"
    func extract(transcript: String, now: Date, calendar: Calendar) async throws -> RawPhraseOutput {
        throw ExtractionRuntimeError.unavailable("test")
    }
}
