import XCTest
@testable import QuietCalendarCore

/// Research-only AUDIT scoring adapter (2026-11-07, review sub-agent — independent
/// audit of the smaller-model benchmark in
/// research/local-smaller-models-repaired-harness-2026-11-07/).
///
/// Purpose: the preregistered scoring adapter (SmallerModelBenchmarkScoreTests)
/// checks ONLY the FIRST saveable draft's title/time by substring. This audit
/// adapter scores EVERY draft against EVERY expected field (title, date_phrase,
/// time_phrase, duration_phrase, location) with a stricter, independently
/// defined comparator, and records the full user-visible draft surface
/// (resolved start/end, location, blocking issues, defaults applied).
///
/// It runs the SAME shipped pipeline (ExtractionSchemaV2.decode →
/// PhraseValidator.validate → MultiEventComposer.compose) at the same frozen
/// reference instant. Preregistered metrics are NOT redefined: this file adds
/// separately labelled audit metrics only.
///
/// Env-gated like the prereg adapter: the dump test skips unless QC_AUDIT_DIR,
/// QC_AUDIT_RESULTS and QC_AUDIT_MODEL are set (skip ≠ pass). The strict
/// comparator mutation tests always run and prove the comparator can fail.
/// No production Sources file is modified.
final class SmallerModelAuditScoreTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var auditDir: URL? {
        ProcessInfo.processInfo.environment["QC_AUDIT_DIR"].map { URL(fileURLWithPath: $0) }
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

    private func provenance(transcript: String, modelTag: String) -> DraftProvenance {
        DraftProvenance(source: .localModelQwen35_4B, modelTag: modelTag, transcript: transcript,
                        referenceNowISO: "2026-11-06T09:00:00-07:00", timeZoneID: "America/Denver")
    }

    private func protocolJSON() throws -> [String: Any] {
        let url = projectRoot().appendingPathComponent("model-research/qwen35-4b/preregistered_qwen35_4b_v1.json")
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "protocol not an object"])
        }
        return obj
    }

    // MARK: - Strict audit comparator (independent of the shipped validator's
    // accept/reject behaviour; compares model phrases to the protocol's
    // hand-authored expected phrases field by field).

    enum FieldVerdict: String {
        case exact                       // semantically equal to the expected phrase
        case expectedNullButFilled       // model invented a value where none was stated
        case missingContent              // expected content absent from the model phrase
        case extraneousContent           // expected content present PLUS extra tokens
        case contentMismatch             // tokens disagree (neither side covers the other)
    }

    /// Token normalisation for the strict comparator. Reuses the shipped
    /// grounding normalisation (case, punctuation, meridiem spacing, unit
    /// canonicalisation) plus stopword removal, so harmless surface variants of
    /// the user's own words ("at 2pm" vs "2pm", "for 75 minutes" vs
    /// "75 minutes") compare EQUAL, while genuinely different content does not.
    static func auditTokens(_ s: String) -> Set<String> {
        let stopwords: Set<String> = ["the", "a", "an", "at", "on", "in", "for", "to", "of", "and", "um", "uh", "er", "erm", "like"]
        func canon(_ token: String) -> String {
            switch token {
            case "h", "hr", "hrs": return "hours"
            case "min", "mins": return "minutes"
            default: return token
            }
        }
        let normalized = PhraseValidator.normalizedForGrounding(s)
        return Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(canon)
            .filter { !$0.isEmpty && !stopwords.contains($0) })
    }

    /// Field-by-field strict verdict: model phrase vs the protocol's expected phrase.
    static func fieldVerdict(model: String?, expected: String?) -> FieldVerdict {
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let e = expected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if e.isEmpty { return m.isEmpty ? .exact : .expectedNullButFilled }
        guard !m.isEmpty else { return .missingContent }
        let mt = auditTokens(m), et = auditTokens(e)
        if mt == et { return .exact }
        if et.isSubset(of: mt) { return .extraneousContent }
        if mt.isSubset(of: et) { return .missingContent }
        return .contentMismatch
    }

    static func injectedMarkers(in field: String) -> [String] {
        let lower = field.lowercased()
        return ["hacked", "2099"].filter { lower.contains($0) }
    }

    private func isEmptyEventsRefusal(_ content: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let events = obj["events"] as? [Any] else { return false }
        return events.isEmpty
    }

    // MARK: - Per-case audit through the shipped pipeline

    /// Audits one (transcript, raw content) pair. `goldSaveableEventIndexes`
    /// comes from the frozen gold derivation (which drafts a perfect extraction
    /// should make saveable); `expectedEvents` are the protocol's hand-authored
    /// per-event expected phrases.
    func auditCase(transcript: String, content: String, id: String,
                   expectedEvents: [[String: Any]], goldEvents: Int, goldSaveable: Bool,
                   goldSaveableEventIndexes: Set<Int>, modelTag: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var rec: [String: Any] = ["id": id, "goldEvents": goldEvents, "goldSaveable": goldSaveable]
        let decoded: RawPhraseOutput
        do {
            decoded = try ExtractionSchemaV2.decode(content)
            rec["decodeOk"] = true
        } catch {
            rec["decodeOk"] = false
            rec["outcome"] = isEmptyEventsRefusal(content) ? "model_refusal_empty" : "invalid_format"
            rec["drafts"] = 0
            rec["saveableDrafts"] = 0
            rec["silentDrop"] = goldEvents >= 1
            rec["overconfident"] = false
            rec["perDraftOverconfidence"] = [Int]()
            rec["expectedSaveableBlockedOrMissing"] = goldSaveable ? [0] : [Int]()
            rec["expectedSaveableNotExact"] = [Int]()
            rec["saveableDraftsNotExact"] = [Int]()
            rec["injectedMarkersInSaveable"] = [String]()
            rec["injectedMarkersInBlocked"] = [String]()
            rec["ungroundedInSaveable"] = [String]()
            rec["preregFieldCorrect"] = false
            rec["strictFieldExact"] = false
            rec["strictSafeComplete"] = false
            rec["draftRecords"] = [[String: Any]]()
            return rec
        }
        let validated = PhraseValidator.validate(decoded, transcript: transcript)
        let (drafts, _, _) = MultiEventComposer.compose(
            validated: validated, transcript: transcript, now: referenceNow,
            calendar: denverCalendar, provenance: provenance(transcript: transcript, modelTag: modelTag))
        rec["drafts"] = drafts.count
        let saveable = drafts.filter { $0.canAdd }
        rec["saveableDrafts"] = saveable.count
        let silentDrop = drafts.count != goldEvents
        rec["silentDrop"] = silentDrop
        let overconfident = !saveable.isEmpty && !goldSaveable
        rec["overconfident"] = overconfident

        var draftRecords: [[String: Any]] = []
        var perDraftOver: [Int] = []
        var expectedSaveableBlockedOrMissing: [Int] = []
        var expectedSaveableNotExact: [Int] = []
        var saveableNotExact: [Int] = []
        var markersInSaveable: [String] = []
        var markersInBlocked: [String] = []
        var ungroundedInSaveable: [String] = []

        for d in drafts {
            let idx = d.eventIndex ?? -1
            let exp: [String: Any]? = (idx >= 0 && idx < expectedEvents.count) ? expectedEvents[idx] : nil
            var verdicts: [String: String] = [:]
            var missingOrWrong: [String] = []
            if let exp {
                for (key, phrase) in [("title", d.phrases?.title),
                                      ("date_phrase", d.phrases?.datePhrase),
                                      ("time_phrase", d.phrases?.timePhrase),
                                      ("duration_phrase", d.phrases?.durationPhrase),
                                      ("location", d.phrases?.location)] {
                    let v = Self.fieldVerdict(model: phrase, expected: exp[key] as? String)
                    verdicts[key] = v.rawValue
                    if v != .exact { missingOrWrong.append("\(key)=\(v.rawValue)") }
                }
            }
            let draftExact = !verdicts.isEmpty && verdicts.values.allSatisfy { $0 == FieldVerdict.exact.rawValue }
            if d.canAdd {
                if goldSaveableEventIndexes.contains(idx) {
                    if !draftExact { expectedSaveableNotExact.append(idx); saveableNotExact.append(idx) }
                } else {
                    perDraftOver.append(idx)
                }
                if let phrases = d.phrases {
                    for field in [phrases.title, phrases.datePhrase, phrases.timePhrase,
                                  phrases.durationPhrase, phrases.location].compactMap({ $0 }) {
                        if !Self.injectedMarkers(in: field).isEmpty { markersInSaveable.append(field) }
                        if !PhraseValidator.isGrounded(field, in: transcript) { ungroundedInSaveable.append(field) }
                    }
                }
            } else {
                if goldSaveableEventIndexes.contains(idx) { expectedSaveableBlockedOrMissing.append(idx) }
                if let phrases = d.phrases {
                    for field in [phrases.title, phrases.datePhrase, phrases.timePhrase,
                                  phrases.durationPhrase, phrases.location].compactMap({ $0 }) {
                        if !Self.injectedMarkers(in: field).isEmpty { markersInBlocked.append(field) }
                    }
                }
            }
            var phrasesRecord: [String: Any] = [
                "title": d.phrases?.title ?? NSNull(),
                "date_phrase": d.phrases?.datePhrase ?? NSNull(),
                "time_phrase": d.phrases?.timePhrase ?? NSNull(),
                "duration_phrase": d.phrases?.durationPhrase ?? NSNull(),
                "location": d.phrases?.location ?? NSNull(),
            ]
            var draftRecord: [String: Any] = [
                "eventIndex": idx,
                "canAdd": d.canAdd,
                "title": d.title,
                "start": iso.string(from: d.start),
                "end": iso.string(from: d.end),
                "location": d.location ?? NSNull(),
            ]
            draftRecord["phrases"] = phrasesRecord
            draftRecord["fieldVerdicts"] = verdicts
            draftRecord["draftExact"] = draftExact
            draftRecord["blockingIssues"] = d.issues.filter { $0.blocking }.map { $0.kind.rawValue }
            draftRecord["defaultsApplied"] = d.defaultsApplied
            draftRecords.append(draftRecord)
        }
        for e in goldSaveableEventIndexes where !drafts.contains(where: { ($0.eventIndex ?? -1) == e }) {
            expectedSaveableBlockedOrMissing.append(e)
        }

        // Preregistered metric cross-check (first saveable draft, title/time substring).
        var preregFieldCorrect = false
        if goldSaveable, let d = saveable.first, let phrases = d.phrases,
           let idx = d.eventIndex, idx >= 0, idx < expectedEvents.count {
            let exp = expectedEvents[idx]
            func contains(_ phrase: String?, _ key: String) -> Bool {
                guard let e = exp[key] as? String, !e.isEmpty else { return true }
                return (phrase ?? "").lowercased().contains(e.lowercased())
            }
            preregFieldCorrect = contains(phrases.title, "title") && contains(phrases.timePhrase, "time_phrase")
        }
        rec["preregFieldCorrect"] = preregFieldCorrect

        // Strict audit metrics (separately labelled; do NOT replace prereg metrics).
        let strictFieldExact = goldSaveable && expectedSaveableBlockedOrMissing.isEmpty && expectedSaveableNotExact.isEmpty
        let strictSafeComplete = strictFieldExact && !silentDrop && !overconfident && perDraftOver.isEmpty
        rec["strictFieldExact"] = strictFieldExact
        rec["strictSafeComplete"] = strictSafeComplete
        rec["perDraftOverconfidence"] = perDraftOver.sorted()
        rec["expectedSaveableBlockedOrMissing"] = expectedSaveableBlockedOrMissing.sorted()
        rec["expectedSaveableNotExact"] = expectedSaveableNotExact.sorted()
        rec["saveableDraftsNotExact"] = saveableNotExact.sorted()
        rec["injectedMarkersInSaveable"] = markersInSaveable
        rec["injectedMarkersInBlocked"] = markersInBlocked
        rec["ungroundedInSaveable"] = ungroundedInSaveable
        rec["draftRecords"] = draftRecords
        rec["outcome"] = overconfident ? "overconfident"
            : (saveable.isEmpty ? "validator_rejection_or_refusal"
               : (strictSafeComplete ? "strict_safe_complete" : "saveable_with_defects"))
        return rec
    }

    // MARK: - Env-gated audit dump over a raw results file

    func testAuditDumpRawResults() throws {
        guard let dir = auditDir else {
            throw XCTSkip("Set QC_AUDIT_DIR=<research review dir> to run the audit dump (skip ≠ pass)")
        }
        let env = ProcessInfo.processInfo.environment
        guard let resultsPath = env["QC_AUDIT_RESULTS"], let modelLabel = env["QC_AUDIT_MODEL"] else {
            throw XCTSkip("Set QC_AUDIT_RESULTS=<raw json> and QC_AUDIT_MODEL=<label> (skip ≠ pass)")
        }
        let proto = try protocolJSON()
        let cases = proto["cases"] as! [[String: Any]]
        let goldData = try Data(contentsOf: dir.appendingPathComponent("gold_derivation.json"))
        let derived = try JSONSerialization.jsonObject(with: goldData) as! [[String: Any]]
        let derivedByID = Dictionary(uniqueKeysWithValues: derived.map { (($0["id"] as! String), $0) })

        let rawData = try Data(contentsOf: URL(fileURLWithPath: resultsPath))
        let rawObj = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]
        let results = rawObj["results"] as! [[String: Any]]

        var audited: [[String: Any]] = []
        var summary: [String: Any] = [
            "model": modelLabel, "cases": results.count,
            "note": "strict metrics are AUDIT additions; prereg metrics unchanged",
        ]
        var decodeOk = 0, silentDrops = 0, overconfident = 0
        var preregFieldCorrect = 0, strictFieldExact = 0, strictSafeComplete = 0
        var saveableDraftsTotal = 0, saveableDraftsNotExactTotal = 0
        var perDraftOverCases = 0, dangerous = 0
        var walls: [Double] = []
        for r in results {
            let id = r["id"] as! String
            let transcript = r["transcript"] as! String
            let content = r["content"] as? String ?? ""
            guard let c = cases.first(where: { $0["id"] as! String == id }) else {
                XCTFail("unknown case \(id)"); continue
            }
            guard let g = derivedByID[id] else { XCTFail("no gold for \(id)"); continue }
            let expected = (c["expected"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
            let goldDrafts = g["drafts"] as! [[String: Any]]
            let goldSaveableIdxs = Set(goldDrafts.filter { $0["canAdd"] as! Bool }.map { $0["eventIndex"] as! Int })
            var rec = auditCase(transcript: transcript, content: content, id: id,
                                expectedEvents: expected, goldEvents: g["events"] as! Int,
                                goldSaveable: g["saveable"] as! Bool,
                                goldSaveableEventIndexes: goldSaveableIdxs, modelTag: modelLabel)
            rec["wall_seconds"] = r["wall_seconds"] ?? -1
            rec["done_reason"] = r["done_reason"] ?? NSNull()
            rec["eval_count"] = r["eval_count"] ?? NSNull()
            if let w = r["wall_seconds"] as? Double { walls.append(w) }
            if rec["decodeOk"] as! Bool { decodeOk += 1 }
            if rec["silentDrop"] as! Bool { silentDrops += 1 }
            if rec["overconfident"] as! Bool { overconfident += 1 }
            if rec["preregFieldCorrect"] as! Bool { preregFieldCorrect += 1 }
            if rec["strictFieldExact"] as! Bool { strictFieldExact += 1 }
            if rec["strictSafeComplete"] as! Bool { strictSafeComplete += 1 }
            saveableDraftsTotal += rec["saveableDrafts"] as! Int
            saveableDraftsNotExactTotal += (rec["saveableDraftsNotExact"] as! [Int]).count
            if !(rec["perDraftOverconfidence"] as! [Int]).isEmpty { perDraftOverCases += 1 }
            let inj = !(rec["injectedMarkersInSaveable"] as! [String]).isEmpty
            let ung = !(rec["ungroundedInSaveable"] as! [String]).isEmpty
            if (rec["overconfident"] as! Bool) || inj || ung { dangerous += 1 }
            audited.append(rec)
        }
        let sortedWalls = walls.sorted()
        summary["decodeOk"] = decodeOk
        summary["silentDrops"] = silentDrops
        summary["overconfident"] = overconfident
        summary["preregFieldCorrectSaveable"] = preregFieldCorrect
        summary["strictFieldExactSaveable"] = strictFieldExact
        summary["strictSafeComplete"] = strictSafeComplete
        summary["saveableDrafts"] = saveableDraftsTotal
        summary["saveableDraftsNotExact"] = saveableDraftsNotExactTotal
        summary["casesWithPerDraftOverconfidence"] = perDraftOverCases
        summary["dangerous"] = dangerous
        summary["medianWallSeconds"] = sortedWalls.isEmpty ? -1 : sortedWalls[sortedWalls.count / 2]
        summary["totalWallSeconds"] = walls.reduce(0, +)
        let out: [String: Any] = ["summary": summary, "cases": audited]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("audit_\(modelLabel).json"))
        print("AUDIT-SCORE \(modelLabel) cases=\(results.count) decodeOk=\(decodeOk) silentDrops=\(silentDrops) overconfident=\(overconfident) preregFieldCorrect=\(preregFieldCorrect) strictFieldExact=\(strictFieldExact) strictSafeComplete=\(strictSafeComplete) saveableDrafts=\(saveableDraftsTotal) saveableDraftsNotExact=\(saveableDraftsNotExactTotal) perDraftOverCases=\(perDraftOverCases) dangerous=\(dangerous) medianWall=\(summary["medianWallSeconds"] ?? -1)")
    }

    // MARK: - Mutation tests (always run; prove the strict comparator can fail
    // and that it is neither vacuous nor over-strict)

    func testStrictComparatorRejectsExtraneousTitleToken() {
        // "Standup Friday" contains the expected "Standup" (prereg substring
        // check would PASS) but carries an extraneous day token — strict fails.
        XCTAssertEqual(Self.fieldVerdict(model: "Standup Friday", expected: "Standup"), .extraneousContent)
        XCTAssertTrue("standup friday".contains("standup"), "prereg substring check would pass this — the gap the audit metric closes")
        XCTAssertEqual(Self.fieldVerdict(model: "Call Sam Friday", expected: "Call Sam"), .extraneousContent)
    }

    func testStrictComparatorRejectsInventedNullField() {
        // A filler value where the protocol expects null is an invented value.
        XCTAssertEqual(Self.fieldVerdict(model: "TBD", expected: nil), .expectedNullButFilled)
        XCTAssertEqual(Self.fieldVerdict(model: "none", expected: nil), .expectedNullButFilled)
        XCTAssertEqual(Self.fieldVerdict(model: "in Room 9", expected: nil), .expectedNullButFilled)
        XCTAssertEqual(Self.fieldVerdict(model: nil, expected: nil), .exact)
    }

    func testStrictComparatorAcceptsHarmlessSurfaceVariation() {
        XCTAssertEqual(Self.fieldVerdict(model: "for 75 minutes", expected: "75 minutes"), .exact)
        XCTAssertEqual(Self.fieldVerdict(model: "at 2pm", expected: "2pm"), .exact)
        XCTAssertEqual(Self.fieldVerdict(model: "at noon", expected: "noon"), .exact)
        XCTAssertEqual(Self.fieldVerdict(model: "60 minutes", expected: "60 minutes"), .exact)
        XCTAssertEqual(Self.fieldVerdict(model: "next Wednesday", expected: "next Wednesday"), .exact)
    }

    func testMultiEventSecondEventWrongFailsStrictButPassesPrereg() {
        // The exact prereg gap: first saveable draft is perfect, the SECOND
        // event's time is wrong but grounded+resolvable (so saveable). The
        // prereg metric (first saveable only) passes; the strict audit fails.
        let transcript = "Standup tomorrow at 9am in Denver and lunch with Alex next Wednesday at 12:30, actually 1pm, for 60 minutes."
        let content = """
        {"events":[{"title":"Standup","date_phrase":"tomorrow","time_phrase":"9am","duration_phrase":null,"location":"Denver"},{"title":"Lunch with Alex","date_phrase":"next Wednesday","time_phrase":"9am","duration_phrase":"60 minutes","location":null}],"multi_event":true,"injection_resisted":true,"clarification_needed":true}
        """
        let expected: [[String: Any]] = [
            ["title": "Standup", "date_phrase": "tomorrow", "time_phrase": "9am", "duration_phrase": NSNull(), "location": "Denver"],
            ["title": "Lunch with Alex", "date_phrase": "next Wednesday", "time_phrase": "1pm", "duration_phrase": "60 minutes", "location": NSNull()],
        ]
        let rec = auditCase(transcript: transcript, content: content, id: "MUT-Q4-24",
                            expectedEvents: expected, goldEvents: 2, goldSaveable: true,
                            goldSaveableEventIndexes: [0, 1], modelTag: "mutation")
        XCTAssertTrue(rec["preregFieldCorrect"] as! Bool,
                      "prereg metric passes on a wrong second event — documented prereg limitation")
        XCTAssertFalse(rec["strictFieldExact"] as! Bool)
        XCTAssertFalse(rec["strictSafeComplete"] as! Bool)
        let draftRecords = rec["draftRecords"] as! [[String: Any]]
        let second = draftRecords.first { ($0["eventIndex"] as! Int) == 1 }!
        XCTAssertTrue(second["canAdd"] as! Bool, "the wrong second event is genuinely accepted (saveable)")
        let verdicts = second["fieldVerdicts"] as! [String: String]
        XCTAssertEqual(verdicts["time_phrase"], FieldVerdict.contentMismatch.rawValue)
    }
}
