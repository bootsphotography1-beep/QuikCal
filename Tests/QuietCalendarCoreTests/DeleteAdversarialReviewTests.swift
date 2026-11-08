import Testing
import Foundation
@testable import QuietCalendarCore

/// REVIEW adversarial regression tests (2026-11-07, independent review).
/// Pins the destructive-phrasing safety contract around the delete
/// discriminator — no GUI, no network, no provider access.
///
/// Finding being pinned: before the review fix, a leading UNSUPPORTED
/// destructive cue ("cancel my dentist appointment tomorrow at 2pm")
/// fell through to the add pipeline and produced an accidental ADD draft
/// titled "cancel my dentist appointment" — the opposite of the user's
/// intent. It now asks for an honest rephrase and nothing is added.
struct DeleteAdversarialReviewTests {

    static func makeParser(now: Date) -> EventParser {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 13; components.hour = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let now = calendar.date(from: components)!
        return EventParser(calendar: calendar, nowProvider: { now })
    }

    static var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 13; components.hour = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar.date(from: components)!
    }

    // MARK: - Unsupported destructive cues never become accidental adds

    @Test func leadingUnsupportedDestructiveCuesAskForRephraseNeverAdd() {
        for phrase in [
            "cancel my dentist appointment",
            "cancel my dentist appointment tomorrow at 2pm",
            "please cancel my lunch on Friday",
            "erase my dentist appointment tomorrow at 2pm",
            "unschedule my dentist appointment tomorrow at 2pm",
            "get rid of my dentist appointment tomorrow at 2pm"
        ] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .needsClarification(let message) = result else {
                Issue.record("unsupported destructive cue must ask for a rephrase, got \(result) for \(phrase)")
                return
            }
            #expect(message == DeleteFlowCopy.unsupportedDestructiveCue)
            // The copy must be truthful: it claims nothing was added, and
            // the ViewModel routes needsClarification to the clarification
            // UI without starting any add parse.
            #expect(message.contains("Nothing was added"))
        }
    }

    @Test func unsupportedDestructiveCueIsNeverADeleteQuery() {
        let result = DeleteIntentDiscriminator.classify(
            "cancel my dentist appointment tomorrow at 2pm",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        if case .deleteQuery = result {
            Issue.record("unsupported destructive cue must never classify as a supported delete")
        }
    }

    // MARK: - Negation still falls through unchanged (never a delete)

    @Test func negatedDestructivePhrasingIsNotADelete() {
        for phrase in [
            "don't cancel my dentist appointment",
            "do not erase my lunch",
            "never unschedule my dentist appointment"
        ] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .notDelete = result else {
                Issue.record("negated destructive phrasing must never classify as delete: \(phrase)")
                return
            }
        }
    }

    // MARK: - Multi-command / injected phrases stay safe

    @Test func deletePlusAddInOnePhraseCannotMatchARealEvent() {
        // "delete X and add Y" classifies as a delete whose title is the
        // full remainder — an exact-title lookup can never match a real
        // event, so the flow ends in an honest no-match. No add runs.
        let result = DeleteIntentDiscriminator.classify(
            "delete my dentist appointment and add lunch with Bob",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .deleteQuery(let query) = result else {
            Issue.record("expected deleteQuery for leading delete + trailing add, got \(result)")
            return
        }
        #expect(query.title == "Dentist appointment and add lunch with Bob")
        // Exact-match policy proves this title cannot match a plausible
        // real event title.
        #expect(!DeleteMatchPolicy.titleMatches(query: query.title, candidate: "dentist appointment"))
        #expect(!DeleteMatchPolicy.titleMatches(query: query.title, candidate: "lunch with Bob"))
    }

    @Test func addPlusDeleteInOnePhraseIsNotADelete() {
        let result = DeleteIntentDiscriminator.classify(
            "add lunch with Bob tomorrow at noon and delete my dentist appointment",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .notDelete = result else {
            Issue.record("mid-phrase delete inside an add request must never classify as delete")
            return
        }
    }

    // MARK: - Non-imperative (past-tense) phrasing is unchanged

    @Test func pastTenseDestructiveWordIsNotAnImperativeCue() {
        // "cancelled …" (past tense) is a statement, not an imperative —
        // the word boundary rejects it and behavior is unchanged
        // (falls through to the add pipeline like any ordinary note).
        let result = DeleteIntentDiscriminator.classify(
            "cancelled my dentist appointment yesterday",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .notDelete = result else {
            Issue.record("past-tense 'cancelled' must not be treated as a destructive imperative")
            return
        }
    }

    // MARK: - Supported delete cues still work after the hardening

    @Test func supportedDeleteCuesAreUnaffectedByTheDestructiveGuard() {
        for phrase in ["delete my dentist appointment tomorrow", "remove my lunch on Friday"] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .deleteQuery = result else {
                Issue.record("supported delete cue must still classify as delete: \(phrase)")
                return
            }
        }
    }
}
