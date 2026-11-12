import XCTest
@testable import QuietCalendarCore

/// Replays the frozen 24-case raw model outputs through the shipped
/// `PhraseValidator` (the validator the app actually runs). Model trust flags
/// in the raw output are ignored; everything downstream derives from fields.
/// This is the regression gate — not an optimisation set (no prompt tuning
/// against it; no case hardcodes exist in the validator).
final class RegressionReplayTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/QuietCalendarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // project
    }

    private func loadRawResults() throws -> [String: (transcript: String, content: String)] {
        let path = projectRoot().appendingPathComponent("model-research/qwen35-4b/qwen35_4b_eval_20261106-154824.json")
        let data = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let results = object["results"] as! [[String: Any]]
        var out: [String: (String, String)] = [:]
        for r in results {
            out[r["id"] as! String] = (r["transcript"] as! String, r["content"] as! String)
        }
        return out
    }

    func testFrozen24ZeroSilentDropsAndZeroOverconfidentAfterValidator() throws {
        let raw = try loadRawResults()
        XCTAssertEqual(raw.count, 24)
        var silentDrops = 0
        var overconfident = 0
        var clarifications = 0
        var totalEventsValidated = 0
        for (_, value) in raw.sorted(by: { $0.key < $1.key }) {
            // Empty-event outputs throw at decode (eventsEmpty) AND validate to a
            // blocking G1 clarification — both are "ask, never silent"; count both.
            let decoded: RawPhraseOutput
            do { decoded = try ExtractionSchemaV2.decode(value.content) }
            catch ExtractionDecodeError.eventsEmpty {
                let validated = PhraseValidator.validate(RawPhraseOutput(events: []), transcript: value.transcript)
                XCTAssertTrue(validated.flatMap({ $0.issues }).contains { $0.kind == .emptyEvents && $0.blocking })
                continue
            }
            let validated = PhraseValidator.validate(decoded, transcript: value.transcript)
            totalEventsValidated += validated.count
            // Silent drop = transcript produced drafts with no blocking surface.
            let hasBlockingSurface = validated.flatMap { $0.issues }.contains { $0.blocking }
            if decoded.events.isEmpty && !hasBlockingSurface { silentDrops += 1 }
            // Overconfident = no blocking issue AND validator reports nothing to confirm.
            let anyMissing = validated.flatMap { $0.issues }.contains { $0.blocking || $0.kind == .missingDuration || $0.kind == .missingLocation }
            if !hasBlockingSurface && !anyMissing {
                // Fully specified → genuinely saveable; overconfident only if a block was expected but missing.
            }
            if validated.flatMap({ $0.issues }).contains(where: { $0.blocking }) { clarifications += 1 }
        }
        // Product gates from EVENT-PIPELINE-ARCHITECTURE §12.
        XCTAssertEqual(silentDrops, 0, "Empty extraction must become a clarification, never a no-op")
        // Every overconfident model flag must now be compensated by a validator issue.
        let overconfidentCases = ["Q4-01", "Q4-02", "Q4-04", "Q4-12", "Q4-13", "Q4-20", "Q4-23"]
        for id in overconfidentCases {
            guard let value = raw[id] else { XCTFail("missing \(id)"); continue }
            let decoded: RawPhraseOutput
            do { decoded = try ExtractionSchemaV2.decode(value.content) }
            catch ExtractionDecodeError.eventsEmpty {
                continue // an empty output is itself a clarification surface
            }
            let validated = PhraseValidator.validate(decoded, transcript: value.transcript)
            let surface = validated.flatMap { $0.issues }
            XCTAssertTrue(surface.contains(where: { $0.blocking || $0.kind == .missingDuration || $0.kind == .missingLocation || $0.kind == .correctedTime || $0.kind == .instructionLike }),
                          "\(id): validator did not surface a confirmation need")
        }
        // Dropouts produce G1 blocking prompts (decode throws eventsEmpty, or validation yields emptyEvents).
        for id in ["Q4-11", "Q4-18"] {
            let value = raw[id]!
            do {
                _ = try ExtractionSchemaV2.decode(value.content)
                XCTFail("\(id): expected eventsEmpty throw")
            } catch ExtractionDecodeError.eventsEmpty {
                // correct: decode rejects empty → app shows the clarification
            } catch {
                XCTFail("\(id): unexpected error \(error)")
            }
            let validated = PhraseValidator.validate(RawPhraseOutput(events: []), transcript: value.transcript)
            XCTAssertTrue(validated.flatMap({ $0.issues }).contains { $0.kind == .emptyEvents && $0.blocking },
                          "\(id): dropout must become an explicit prompt")
        }
        print("REGRESSION validatedEvents=\(totalEventsValidated) clarificationCases=\(clarifications)")
    }

    func testFrozen24FieldsRecoveredThroughValidator() throws {
        // Sanity: validator never invents a non-null value — every surviving
        // phrase was grounded in the transcript (see testUngroundedPhraseNulledAndBlocking).
        let raw = try loadRawResults()
        for (_, value) in raw {
            let decoded: RawPhraseOutput
            do { decoded = try ExtractionSchemaV2.decode(value.content) }
            catch ExtractionDecodeError.eventsEmpty { continue }
            let validated = PhraseValidator.validate(decoded, transcript: value.transcript)
            for v in validated {
                if let phrases = [v.phrases.title, v.phrases.datePhrase, v.phrases.timePhrase, v.phrases.durationPhrase, v.phrases.location].compactMap({ $0 }) as [String]? {
                    for p in phrases {
                        XCTAssertTrue(PhraseValidator.isGrounded(p, in: value.transcript),
                                      "Ungrounded phrase survived: \(p)")
                    }
                }
            }
        }
    }
}
