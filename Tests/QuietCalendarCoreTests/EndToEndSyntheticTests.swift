import XCTest
@testable import QuietCalendarCore

/// End-to-end synthetic verification (gated): synthetic speech fixture transcript
/// (fixture, not mic audio) → deterministic extractor → resolver → confirmation
/// draft → mock EventKit sink. Verifies the full offline chain without
/// mic/GUI/permissions and without claiming a real calendar write.
@MainActor
final class EndToEndSyntheticTests: XCTestCase {
    func testSyntheticFixtureToConfirmationDraftToMockSink() async throws {
        guard ProcessInfo.processInfo.environment["QC_RUN_PACKAGED_SYNTHETIC"] == "1" else {
            throw XCTSkip("Set QC_RUN_PACKAGED_SYNTHETIC=1 for the synthetic end-to-end chain (skip ≠ pass)")
        }
        // Synthetic fixture transcript (no mic, no GUI) — same fixture family as
        // SYNTHETIC_NOT_MIC_meeting_noon_sturm_16k_mono.wav.
        let transcript = "Meeting at noon for something in Sturm 320."
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 6
        comps.hour = 9; comps.timeZone = TimeZone(identifier: "America/Denver")
        let now = calendar.date(from: comps)!

        let pipeline = PhrasePipeline(phraseRuntime: nil, calendar: calendar)
        let outcome = await pipeline.run(transcript: transcript, now: now)
        guard case .drafts(var drafts, _) = outcome.set else {
            XCTFail("synthetic fixture must produce a draft"); return
        }
        XCTAssertFalse(drafts.isEmpty)
        // Draft serialisation round-trips (save/refresh across popover reopen).
        let data = try JSONEncoder().encode(drafts)
        let decoded = try JSONDecoder().decode([ConfirmationDraft].self, from: data)
        XCTAssertEqual(decoded.count, drafts.count)

        let sink = MockCalendarSink()
        let result = WriteCoordinator().write(drafts: drafts, calendarID: "test-calendar", sink: sink)
        XCTAssertTrue(result.anySaved)
        XCTAssertEqual(sink.committed.count, drafts.count)
        drafts = drafts.map { draft in
            var d = draft
            if let outcome = result.outcomes[d.id], case .created(let id) = outcome {
                d.savedEventID = id
            }
            return d
        }
        XCTAssertTrue(drafts.allSatisfy { $0.savedEventID != nil })
        print("E2E synthetic drafts=\(drafts.count) committed=\(sink.committed.count) (mock sink — not a real calendar write)")
    }

    func testSyntheticFixtureWithAppleFoundationModelsWhenAvailable() async throws {
        guard FoundationModelsReadiness.current.isAvailable else {
            throw XCTSkip(FoundationModelsReadiness.current.userFacingText)
        }
        let transcript = "Meeting at noon for something in Sturm 320."
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 6
        comps.hour = 9; comps.timeZone = TimeZone(identifier: "America/Denver")
        let now = calendar.date(from: comps)!

        let runtime = FoundationModelsPhraseRuntime()
        let raw = try await runtime.extract(transcript: transcript, now: now, calendar: calendar)
        XCTAssertFalse(raw.events.isEmpty)
        let validated = PhraseValidator.validate(raw, transcript: transcript)
        XCTAssertEqual(validated.count, raw.events.count)
        // Synthetic-only extraction and validation: this test never reaches a write sink.
    }
}
