import Testing
import Foundation
@testable import QuietCalendarCore

// 0.3.17 voice-review semantics regression sources (NOT RUN in this pass —
// the owner explicitly limited verification to one release build + essential
// signing/no-secret/DMG checks; these encode the intended contracts for the
// next full test run).
//
// Covers the three 0.3.17 fixes:
// 1. Semantic title + description from speech/typing (deterministic parser).
// 2. Stable voice-bar width while words stream (no per-word recentering).
// 3. Notes carry-through: intent → draft → confirmation draft → sinks.

@Suite
struct VoiceReviewSemantic20261108Tests {
    private func intent(_ text: String) -> EventIntent? {
        let now = Date(timeIntervalSince1970: 1_793_880_000) // fixed reference
        switch EventParser().extractIntent(text, now: now) {
        case .intent(let intent): return intent
        default: return nil
        }
    }

    // MARK: - Semantic title + description

    @Test func conciseTitleFromMeetingPurposePattern() {
        // Owner example: the raw utterance must NOT become the title; the
        // actual activity + person form the concise name; tomorrow/3/reminder
        // parse independently.
        let parsed = intent("Schedule a meeting with Alex tomorrow at 3pm to review the Q4 budget, remind me 30 minutes before")
        #expect(parsed != nil)
        #expect(parsed?.title == "Q4 budget review with Alex")
        // The Q4 context lives in the title; no invented description filler.
        #expect(parsed?.notes == nil)
        #expect(parsed?.reminderLeadMinutes == 30)
        #expect(parsed?.date != nil)
        #expect(parsed?.time != nil)
    }

    @Test func bareNounTitleCapitalizedEmptyDescription() {
        // "just dentist tomorrow at 3" → "Dentist", NO invented filler.
        let parsed = intent("just dentist tomorrow at 3pm")
        #expect(parsed?.title == "Dentist")
        #expect(parsed?.notes == nil)
    }

    @Test func detailClausesBecomeDescriptionNotTitle() {
        let parsed = intent("dentist tomorrow at 3pm, bring my insurance card")
        #expect(parsed?.title == "Dentist")
        #expect(parsed?.notes == "Bring my insurance card")
    }

    @Test func explicitUserTitleWinsVerbatim() {
        let parsed = intent("add an event called Standup review tomorrow at 9am")
        #expect(parsed?.title == "Standup review")
        #expect(parsed?.notes == nil)
    }

    @Test func requestBoilerplateStrippedFromTitle() {
        let parsed = intent("please schedule team lunch friday at 1pm on my calendar")
        #expect(parsed?.title == "Team lunch")
        #expect(parsed?.notes == nil)
    }

    @Test func meaningfulNamesKeptNoGenericDegrade() {
        // A specific activity never degrades into a generic "Event"/"Meeting".
        let parsed = intent("lunch with Dana tomorrow at noon")
        #expect(parsed?.title == "Lunch with Dana")
    }

    // MARK: - Stable streaming width

    @Test func widthStableAcrossWordCounts() {
        let w1 = VoiceBarWidthPolicy.width(previewCharacterCount: 5, visibleFrameWidth: 1440)
        let w2 = VoiceBarWidthPolicy.width(previewCharacterCount: 50, visibleFrameWidth: 1440)
        let w3 = VoiceBarWidthPolicy.width(previewCharacterCount: 500, visibleFrameWidth: 1440)
        #expect(w1 == w2)
        #expect(w2 == w3)
        #expect(VoiceBarWidthPolicy.width(previewCharacterCount: 0, visibleFrameWidth: 1440)
                == VoiceBarWidthPolicy.compactWidth)
    }

    // MARK: - Notes carry-through

    @Test func resolverCarriesNotesIntoDraft() {
        let now = Date(timeIntervalSince1970: 1_793_880_000)
        let parsed = EventParser().parse("dentist tomorrow at 3pm, bring my insurance card", now: now)
        guard case .event(let draft) = parsed else {
            Issue.record("expected a resolved draft"); return
        }
        #expect(draft.title == "Dentist")
        #expect(draft.notes == "Bring my insurance card")
    }

    @Test func schemaDecodesNotesAdditively() throws {
        // Old frozen outputs (no "notes" key) still decode; new outputs carry it.
        let oldJSON = #"{"events":[{"title":"T","date_phrase":"tomorrow","time_phrase":"9am","duration_phrase":null,"location":null}]}"#
        let old = try ExtractionSchemaV2.decode(oldJSON)
        #expect(old.events.first?.notes == nil)

        let newJSON = #"{"events":[{"title":"T","date_phrase":"tomorrow","time_phrase":"9am","duration_phrase":null,"location":null,"notes":"bring the card"}]}"#
        let new = try ExtractionSchemaV2.decode(newJSON)
        #expect(new.events.first?.notes == "bring the card")
    }

    @Test func confirmationDraftDecodesNotesBackwardCompatibly() throws {
        // Drafts encoded before 0.3.17 (no "notes" key) decode with nil.
        let json = #"{"id":"\#(UUID().uuidString)","title":"T","start":0,"end":10,"location":null,"source":"builtInParser","provenance":{"source":"builtInParser","transcript":"t","referenceNowISO":"2026-11-08T00:00:00Z","timeZoneID":"UTC"}}"#
        let draft = try JSONDecoder().decode(ConfirmationDraft.self, from: Data(json.utf8))
        #expect(draft.notes == nil)
    }

    @Test func googleBodyIncludesDescriptionOnlyWhenProvided() throws {
        let start = Date(timeIntervalSince1970: 1_793_880_000)
        let withNotes = try GoogleEventBodyBuilder.body(
            title: "T", start: start, end: start.addingTimeInterval(3600),
            location: nil, notes: "bring the card")
        let object = try JSONSerialization.jsonObject(with: withNotes) as? [String: Any]
        #expect(object?["description"] as? String == "bring the card")

        let withoutNotes = try GoogleEventBodyBuilder.body(
            title: "T", start: start, end: start.addingTimeInterval(3600),
            location: nil, notes: nil)
        let object2 = try JSONSerialization.jsonObject(with: withoutNotes) as? [String: Any]
        #expect(object2?["description"] == nil)
    }
}
