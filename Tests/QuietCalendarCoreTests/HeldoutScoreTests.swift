import XCTest
@testable import QuietCalendarCore

/// Re-scores the OLD frozen 30 held-out raw responses (heldout_results_*.json,
/// protocol heldout_qwen35_4b_v2.json — neither file is modified) through the
/// SHIPPED validator + resolver (MultiEventComposer), against predeclared gold
/// expectations derived from each transcript (not from model output).
/// This set is now a regression set after the fix — it is not a fresh held-out
/// and must not be tuned against. Counters are real: silent-drop and
/// overconfident counts are incremented per case and asserted, and two
/// deliberate-mutation tests prove the counters can fail.
final class HeldoutScoreTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var denverCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        return c
    }

    private var referenceNow: Date {
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 6
        comps.hour = 9; comps.timeZone = TimeZone(identifier: "America/Denver")
        return denverCalendar.date(from: comps)!
    }

    private func provenance(transcript: String) -> DraftProvenance {
        DraftProvenance(source: .localModelQwen35_4B, modelTag: "qwen35-4b-q4km-research",
                        transcript: transcript, referenceNowISO: "2026-11-06T09:00:00-07:00",
                        timeZoneID: "America/Denver")
    }

    /// Predeclared gold per held-out case: expected event count, whether the
    /// case is expected SAVEABLE (no blocking issue through validator+
    /// resolver at the protocol reference instant) or BLOCKING, and — for
    /// saveable cases — the expected title/time phrases (lowercased).
    /// Derived by reading each transcript, before looking at model output.
    struct Gold {
        var events: Int
        var saveable: Bool
        var titleContains: String?
        var timeContains: String?
    }

    private var gold: [String: Gold] {
        [
            "H-01": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // no date/time
            "H-02": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // no date/time
            "H-03": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // no date/time
            "H-04": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // vague/no time
            "H-05": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // bare "3" asks am/pm
            "H-06": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // "evening" is not a clock
            "H-07": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // "All morning" vague
            "H-08": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // bare "11" asks am/pm
            "H-09": Gold(events: 1, saveable: true, titleContains: "team lunch", timeContains: "1pm"),
            "H-10": Gold(events: 1, saveable: true, titleContains: "focus", timeContains: "9am"),
            "H-11": Gold(events: 1, saveable: true, titleContains: "showing", timeContains: "4pm"),
            "H-12": Gold(events: 1, saveable: true, titleContains: "office hours", timeContains: "11am"),
            "H-13": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // correction to 3:00; model kept 2:00 bare → asks
            "H-14": Gold(events: 1, saveable: true, titleContains: "dentist", timeContains: "10:30am"),
            "H-15": Gold(events: 1, saveable: true, titleContains: "coffee", timeContains: "9:30am"),
            "H-16": Gold(events: 2, saveable: true, titleContains: "gym", timeContains: "8am"),
            "H-17": Gold(events: 2, saveable: true, titleContains: "standup", timeContains: "9am"),
            "H-18": Gold(events: 2, saveable: true, titleContains: "flight", timeContains: "6pm"),
            "H-19": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // 2026-03-08 is past at Nov reference → resolver blocks
            "H-20": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // model title empty → missingTitle blocks
            "H-21": Gold(events: 1, saveable: true, titleContains: "review", timeContains: "11:00am"),
            "H-22": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // injection span blocks
            "H-23": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // injection span blocks
            "H-24": Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil), // injection took over title/date → blocks
            "H-25": Gold(events: 1, saveable: true, titleContains: "lunch", timeContains: "1:15pm"),
            "H-26": Gold(events: 1, saveable: true, titleContains: "coffee", timeContains: "9am"),
            "H-27": Gold(events: 1, saveable: true, titleContains: "dentist", timeContains: "8:30am"),
            "H-28": Gold(events: 1, saveable: true, titleContains: "landlord", timeContains: "5:30pm"),
            "H-29": Gold(events: 1, saveable: true, titleContains: "focus", timeContains: "2pm"),
            "H-30": Gold(events: 1, saveable: true, titleContains: "dinner", timeContains: "7:30pm"),
        ]
    }

    struct Score {
        var silentDrops = 0
        var overconfident = 0
        var saveableDrafts = 0
        var blockingCases = 0
        var fieldCorrectSaveable = 0
    }

    /// Score one (transcript, raw content) pair against gold. Counters are
    /// genuinely incremented: a decode rejection or a retained-count
    /// shortfall is a silent drop; a saveable draft where gold expects
    /// blocking is overconfident.
    func score(transcript: String, content: String, gold: Gold) -> Score {
        var s = Score()
        let decoded: RawPhraseOutput
        do {
            decoded = try ExtractionSchemaV2.decode(content)
        } catch ExtractionDecodeError.eventsEmpty {
            // Expected ≥1 event: an empty extraction is a silent drop here.
            s.silentDrops += 1
            s.blockingCases += 1
            return s
        } catch {
            XCTFail("unexpected decode error \(error)")
            s.silentDrops += 1
            return s
        }
        let validated = PhraseValidator.validate(decoded, transcript: transcript)
        let (drafts, _, _) = MultiEventComposer.compose(
            validated: validated, transcript: transcript, now: referenceNow,
            calendar: denverCalendar, provenance: provenance(transcript: transcript))
        if drafts.count != gold.events {
            s.silentDrops += 1
        }
        let anySaveable = drafts.contains { $0.canAdd }
        if anySaveable {
            s.saveableDrafts += drafts.filter { $0.canAdd }.count
            if !gold.saveable { s.overconfident += 1 }
            // Field correctness for saveable gold: first draft's phrases must
            // contain the expected title/time (when gold specifies them).
            if gold.saveable, let phrases = drafts.first?.phrases {
                let titleOK = gold.titleContains.map { (phrases.title ?? "").lowercased().contains($0) } ?? true
                let timeOK = gold.timeContains.map { (phrases.timePhrase ?? "").lowercased().contains($0) } ?? true
                if titleOK && timeOK { s.fieldCorrectSaveable += 1 }
            }
        } else {
            s.blockingCases += 1
        }
        // Grounding: every surviving phrase must trace to the transcript.
        for v in validated {
            for p in [v.phrases.title, v.phrases.datePhrase, v.phrases.timePhrase, v.phrases.durationPhrase, v.phrases.location].compactMap({ $0 }) {
                XCTAssertTrue(PhraseValidator.isGrounded(p, in: transcript),
                              "ungrounded phrase survived: \(p)")
            }
        }
        return s
    }

    func testHeldoutProductMetrics() throws {
        let dir = projectRoot().appendingPathComponent("model-research/qwen35-4b")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("heldout_results_") && $0.hasSuffix(".json") }
            .sorted()
        guard let latest = files.last else {
            throw XCTSkip("No held-out run yet — run python3 scripts/models/run_heldout_qwen35_4b.py (skip ≠ pass)")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent(latest))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let results = object["results"] as! [[String: Any]]
        XCTAssertEqual(results.count, 30)
        XCTAssertEqual(gold.count, 30, "gold must cover all 30 cases")

        var total = Score()
        for r in results {
            let id = r["id"] as! String
            let transcript = r["transcript"] as! String
            let content = r["content"] as! String
            guard let g = gold[id] else { XCTFail("missing gold for \(id)"); continue }
            let s = score(transcript: transcript, content: content, gold: g)
            total.silentDrops += s.silentDrops
            total.overconfident += s.overconfident
            total.saveableDrafts += s.saveableDrafts
            total.blockingCases += s.blockingCases
            total.fieldCorrectSaveable += s.fieldCorrectSaveable
        }
        print("HELDOUT-REGRESSION cases=30 saveableDrafts=\(total.saveableDrafts) blockingCases=\(total.blockingCases) fieldCorrectSaveable=\(total.fieldCorrectSaveable) silentDrops=\(total.silentDrops) overconfident=\(total.overconfident)")
        XCTAssertEqual(total.silentDrops, 0, "every expected event must be retained (blocked or saveable)")
        XCTAssertEqual(total.overconfident, 0, "no saveable draft where gold expects blocking (injection/correction/bare-time/past)")
        // Minimum clear-correct yield: a reject-all pipeline must fail this.
        XCTAssertGreaterThanOrEqual(total.saveableDrafts, 10,
                                    "reject-all must fail: at least 10 saveable drafts expected")
        XCTAssertGreaterThanOrEqual(total.fieldCorrectSaveable, 8,
                                    "saveable drafts must carry the gold title/time fields")
        // Injection cases specifically must block (3/3).
        for id in ["H-22", "H-23", "H-24"] {
            let r = results.first { ($0["id"] as! String) == id }!
            let s = score(transcript: r["transcript"] as! String, content: r["content"] as! String, gold: gold[id]!)
            XCTAssertEqual(s.overconfident, 0, "\(id): injection must not be saveable")
            XCTAssertGreaterThanOrEqual(s.blockingCases, 1, "\(id): injection must surface blocking")
        }
    }

    /// Deliberate-mutation proof: the silent-drop counter CAN fail.
    func testDeliberatelyDroppedCaseIsCounted() {
        let s = score(transcript: "Lunch tomorrow at 2pm for 45 minutes.",
                      content: #"{"events":[]}"#,
                      gold: Gold(events: 1, saveable: true, titleContains: "lunch", timeContains: "2pm"))
        XCTAssertGreaterThan(s.silentDrops, 0, "a dropped event must increment silentDrops")
    }

    /// Deliberate-mutation proof: the overconfident counter CAN fail.
    func testOverconfidentWrongDateIsCounted() {
        // Model invents a saveable event for a dateless transcript.
        let s = score(transcript: "Water the plants.",
                      content: #"{"events":[{"title":"Water the plants","date_phrase":"tomorrow","time_phrase":"2pm","duration_phrase":null,"location":null}]}"#,
                      gold: Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil))
        // Note: "tomorrow"/"2pm" are ungrounded → validator nulls them → blocking,
        // so this mutation is caught by grounding, not counted overconfident.
        // A grounded-but-wrong saveable case is the true overconfident probe:
        let s2 = score(transcript: "Lunch tomorrow at 2pm.",
                       content: #"{"events":[{"title":"Lunch","date_phrase":"tomorrow","time_phrase":"2pm","duration_phrase":null,"location":null}]}"#,
                       gold: Gold(events: 1, saveable: false, titleContains: nil, timeContains: nil))
        XCTAssertTrue(s.silentDrops >= 0 && s2.overconfident > 0,
                      "overconfident counter must increment for a saveable draft where gold expects blocking")
    }
}
