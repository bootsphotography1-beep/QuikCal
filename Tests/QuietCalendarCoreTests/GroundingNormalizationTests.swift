import XCTest
@testable import QuietCalendarCore

/// Grounding-normalisation tests (2026-11-06 research pass).
///
/// Models legitimately emit harmless surface variants of verbatim phrases —
/// most commonly splitting a digit+meridiem run ("3pm" → "3 pm") or expanding
/// "p.m." — and the grounding check must not reject those as invented while
/// still rejecting genuinely ungrounded content.
final class GroundingNormalizationTests: XCTestCase {

    // MARK: - isGrounded acceptance (harmless normalisation)

    func testGroundingAcceptsSpaceNormalizedMeridiem() {
        // Model returned "3 pm"; transcript says "3pm".
        XCTAssertTrue(PhraseValidator.isGrounded("3 pm", in: "Dentist Thursday 3pm 45 minutes Main Clinic"))
        // And the reverse direction.
        XCTAssertTrue(PhraseValidator.isGrounded("3pm", in: "Dentist Thursday 3 pm 45 minutes Main Clinic"))
    }

    func testGroundingAcceptsPeriodMeridiemVariants() {
        XCTAssertTrue(PhraseValidator.isGrounded("3pm", in: "Dentist Thursday 3 p.m. Main Clinic"))
        XCTAssertTrue(PhraseValidator.isGrounded("3 pm", in: "Dentist Thursday 3 p.m. Main Clinic"))
        XCTAssertTrue(PhraseValidator.isGrounded("10am", in: "Standup 10 a.m. Monday"))
    }

    func testGroundingAcceptsDurationUnitNormalization() {
        XCTAssertTrue(PhraseValidator.isGrounded("45 min", in: "Dentist Thursday 3pm 45 minutes Main Clinic"))
        XCTAssertTrue(PhraseValidator.isGrounded("45 minutes", in: "Dentist Thursday 3pm 45min Main Clinic"))
        XCTAssertTrue(PhraseValidator.isGrounded("1.5 hours", in: "Workshop 1.5h Friday"))
    }

    // MARK: - isGrounded rejections (must NOT be loosened)

    func testGroundingStillRejectsFabricatedMeridiem() {
        // "pm" appears nowhere in the transcript — the split must not invent it.
        XCTAssertFalse(PhraseValidator.isGrounded("3 pm", in: "Room 3 booking at noon"))
    }

    func testGroundingStillRejectsWrongNumber() {
        XCTAssertFalse(PhraseValidator.isGrounded("7 pm", in: "Dentist Thursday 3pm"))
    }

    func testGroundingStillRejectsInventedWords() {
        XCTAssertFalse(PhraseValidator.isGrounded("HACKED", in: "Lunch with Alex tomorrow noon"))
        XCTAssertFalse(PhraseValidator.isGrounded("2099-01-01", in: "Lunch with Alex tomorrow noon"))
    }

    // MARK: - Validator end-to-end: normalised phrase survives

    func testNormalizedTimePhraseNotNulledByValidator() {
        let transcript = "Dentist Thursday 3pm 45 minutes Main Clinic"
        let raw = RawPhraseOutput(events: [RawPhraseEvent(
            title: "Dentist", datePhrase: "Thursday", timePhrase: "3 pm",
            durationPhrase: "45 minutes", location: "Main Clinic")])
        let validated = PhraseValidator.validate(raw, transcript: transcript)
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].phrases.timePhrase, "3 pm")
        XCTAssertFalse(validated[0].hasBlockingIssue,
                       "normalised meridiem spacing must not block: \(validated[0].issues)")
    }

    func testPeriodMeridiemPhraseNotNulledByValidator() {
        let transcript = "Standup 10 a.m. Monday Room 4"
        let raw = RawPhraseOutput(events: [RawPhraseEvent(
            title: "Standup", datePhrase: "Monday", timePhrase: "10am",
            durationPhrase: nil, location: "Room 4")])
        let validated = PhraseValidator.validate(raw, transcript: transcript)
        XCTAssertEqual(validated[0].phrases.timePhrase, "10am")
        XCTAssertFalse(validated[0].hasBlockingIssue,
                       "a.m./p.m. variants must not block: \(validated[0].issues)")
    }

    // MARK: - segmentScope: locate the event segment when the model normalised the phrase

    func testSegmentScopeFindsNormalizedTimePhrase() {
        let transcript = "Brunch Saturday afternoon 3pm and flight Sunday 7am"
        // Model split "3pm" into "3 pm"; exact word-boundary match fails, the
        // whitespace-insensitive retry must still find the first segment.
        let scope = PhraseValidator.segmentScope(transcript: transcript, timePhrase: "3 pm")
        XCTAssertEqual(scope, "Brunch Saturday afternoon 3pm")
        XCTAssertEqual(PhraseValidator.contextualMeridiem(transcript: transcript, timePhrase: "3 pm"), .pm)
    }

    func testSegmentScopeStillRefusesCrossEventInferenceWhenUnmatched() {
        let transcript = "Brunch Saturday afternoon 3pm and flight Sunday 7am"
        // A phrase that appears in neither segment must not fall back to the
        // whole transcript (no qualifier bleeding across events).
        let scope = PhraseValidator.segmentScope(transcript: transcript, timePhrase: "9 pm")
        XCTAssertEqual(scope, "")
    }

    // MARK: - Review addition: conflicting qualifiers must ask, never guess (S3)

    func testConflictingQualifiersInSameEventAskAndNeverGuess() {
        // Both a morning and an afternoon qualifier in the SAME event segment:
        // the validator must raise blocking ampmAmbiguous, not present a guessed
        // meridiem as a non-blocking "inferred" correction. (Independent review
        // 2026-11-06: the `if let ctx` branch previously caught .conflicting and
        // emitted "Inferred pm from "conflicting" context", leaving the
        // .conflicting branch dead code.)
        let transcript = "Sync with Dana Friday 3 morning or afternoon works"
        let raw = RawPhraseOutput(events: [RawPhraseEvent(
            title: "Sync with Dana", datePhrase: "Friday", timePhrase: "3",
            durationPhrase: nil, location: nil)])
        let validated = PhraseValidator.validate(raw, transcript: transcript)
        XCTAssertTrue(validated[0].issues.contains { $0.kind == .ampmAmbiguous && $0.blocking },
                      "conflicting qualifiers must ask am/pm: \(validated[0].issues)")
        XCTAssertFalse(validated[0].issues.contains { $0.kind == .correctedTime },
                       "must not present a guessed meridiem as inferred: \(validated[0].issues)")
    }

    // MARK: - End-to-end resolution with normalised phrases

    func testNormalizedPhrasesResolveEndToEnd() {
        // Reference: Fri 2026-11-06 09:00 America/Denver (DST fall-back already
        // passed Nov 1) → Thursday next = 2026-11-12, 3pm = 15:00 MST (-07:00).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        let now = try! XCTUnwrap(DateComponents(
            calendar: cal, timeZone: cal.timeZone,
            year: 2026, month: 11, day: 6, hour: 9, minute: 0).date)
        let phrases = EventPhrases(
            title: "Dentist", datePhrase: "Thursday", timePhrase: "3 pm",
            durationPhrase: "45 minutes", location: "Main Clinic")
        let provenance = DraftProvenance(
            source: .localModelQwen35_4B, modelTag: "research",
            transcript: "Dentist Thursday 3pm 45 minutes Main Clinic",
            referenceNowISO: "2026-11-06T09:00:00-07:00", timeZoneID: "America/Denver")
        let resolution = DateResolver(calendar: cal).resolve(
            phrases, transcript: "Dentist Thursday 3pm 45 minutes Main Clinic",
            now: now, provenance: provenance)
        guard case .resolved(let draft) = resolution else {
            XCTFail("expected resolution, got \(resolution)")
            return
        }
        let start = cal.dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        XCTAssertEqual([start.year, start.month, start.day, start.hour, start.minute],
                       [2026, 11, 12, 15, 0])
    }
}
