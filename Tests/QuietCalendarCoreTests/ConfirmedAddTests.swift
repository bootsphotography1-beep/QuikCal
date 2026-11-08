import Testing
import Foundation
@testable import QuietCalendarCore

@MainActor
private final class MockCalendarSink: CalendarEventSink {
    struct RecordedAdd: Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var reminderLeadMinutes: Int?
        var calendarID: String
    }

    var existing: [(title: String, start: Date, end: Date, location: String?)] = []
    var adds: [RecordedAdd] = []
    var nextID: Int = 1
    var failWith: String?

    func hasExactMatch(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        calendarID: String
    ) -> Bool {
        existing.contains {
            EventExactMatch.matches(
                title: title,
                start: start,
                end: end,
                location: location,
                candidateTitle: $0.title,
                candidateStart: $0.start,
                candidateEnd: $0.end,
                candidateLocation: $0.location
            )
        }
    }

    func addEvent(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?,
        reminderLeadMinutes: Int?,
        calendarID: String
    ) throws -> String {
        if let failWith {
            throw NSError(domain: "MockCalendar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: failWith
            ])
        }
        adds.append(RecordedAdd(
            title: title,
            start: start,
            end: end,
            location: location,
            reminderLeadMinutes: reminderLeadMinutes,
            calendarID: calendarID
        ))
        existing.append((title, start, end, location))
        defer { nextID += 1 }
        return "evt-\(nextID)"
    }
}

@MainActor
struct ConfirmedAddTests {
    let start = Date(timeIntervalSince1970: 1_793_880_000) // fixed
    var end: Date { start.addingTimeInterval(3600) }

    func request(allowDuplicate: Bool = false) -> ConfirmedAddRequest {
        ConfirmedAddRequest(
            title: "Standup",
            start: start,
            end: end,
            location: nil,
            calendarID: "cal-1",
            allowDuplicate: allowDuplicate
        )
    }

    @Test func sequentialDoubleSubmitUsesDraftTokenNotJustConcurrentFlag() {
        let sink = MockCalendarSink()
        var writer = ConfirmedEventAdd()
        writer.beginNewDraft()

        let first = writer.submit(request(), sink: sink)
        #expect(first == .created(id: "evt-1"))
        #expect(sink.adds.count == 1)

        // Same confirmation token — second submit must not write again.
        let second = writer.submit(request(), sink: sink)
        #expect(second == .alreadyCommitted)
        #expect(sink.adds.count == 1)
    }

    @Test func failureDoesNotConsumeTokenSoRetryCanWrite() {
        let sink = MockCalendarSink()
        sink.failWith = "EventKit save failed"
        var writer = ConfirmedEventAdd()
        writer.beginNewDraft()

        let failed = writer.submit(request(), sink: sink)
        guard case .failed(let message) = failed else {
            Issue.record("expected failure"); return
        }
        #expect(message.contains("EventKit save failed"))
        #expect(sink.adds.isEmpty)
        #expect(writer.gate.canCommit)

        sink.failWith = nil
        let retried = writer.submit(request(), sink: sink)
        #expect(retried == .created(id: "evt-1"))
        #expect(sink.adds.count == 1)
    }

    @Test func exactMatchWarnsWithoutWritingUntilAllowDuplicate() {
        let sink = MockCalendarSink()
        sink.existing = [("Standup", start, end, nil)]
        var writer = ConfirmedEventAdd()
        writer.beginNewDraft()

        let warned = writer.submit(request(allowDuplicate: false), sink: sink)
        #expect(warned == .exactMatchNeedsConfirmation)
        #expect(sink.adds.isEmpty)
        #expect(writer.gate.canCommit)

        let forced = writer.submit(request(allowDuplicate: true), sink: sink)
        #expect(forced == .created(id: "evt-1"))
        #expect(sink.adds.count == 1)
    }

    @Test func newDraftTokenAllowsIntentionalRepeatAfterReconfirm() {
        let sink = MockCalendarSink()
        var writer = ConfirmedEventAdd()
        writer.beginNewDraft()
        #expect(writer.submit(request(), sink: sink) == .created(id: "evt-1"))

        // Re-parse / new confirmation mints a fresh token; exact match then warns.
        writer.beginNewDraft()
        #expect(writer.submit(request(), sink: sink) == .exactMatchNeedsConfirmation)
        #expect(sink.adds.count == 1)

        #expect(writer.submit(request(allowDuplicate: true), sink: sink) == .created(id: "evt-2"))
        #expect(sink.adds.count == 2)
    }

    @Test func exactMatchHelperComparesNormalizedLocation() {
        #expect(
            EventExactMatch.matches(
                title: "A",
                start: start,
                end: end,
                location: "  Room 1 ",
                candidateTitle: "A",
                candidateStart: start,
                candidateEnd: end,
                candidateLocation: "Room 1"
            )
        )
        #expect(
            !EventExactMatch.matches(
                title: "A",
                start: start,
                end: end,
                location: nil,
                candidateTitle: "A",
                candidateStart: start,
                candidateEnd: end,
                candidateLocation: "Elsewhere"
            )
        )
    }
}

struct NoteInteractionGateTests {
    @Test func parseDisabledWhileSpeechActive() {
        #expect(
            !NoteInteractionGate.canParse(
                isParsing: false,
                isSaving: false,
                speechPhase: .active,
                noteIsEmpty: false
            )
        )
        #expect(
            NoteInteractionGate.canParse(
                isParsing: false,
                isSaving: false,
                speechPhase: .idle,
                noteIsEmpty: false
            )
        )
    }

    @Test func parseDisabledWhileParsingOrSavingOrEmpty() {
        #expect(
            !NoteInteractionGate.canParse(
                isParsing: true,
                isSaving: false,
                speechPhase: .idle,
                noteIsEmpty: false
            )
        )
        #expect(
            !NoteInteractionGate.canParse(
                isParsing: false,
                isSaving: true,
                speechPhase: .idle,
                noteIsEmpty: false
            )
        )
        #expect(
            !NoteInteractionGate.canParse(
                isParsing: false,
                isSaving: false,
                speechPhase: .idle,
                noteIsEmpty: true
            )
        )
    }

    @Test func lateTranscriptIgnoredOffNoteOrDuringParseSave() {
        #expect(
            !NoteInteractionGate.shouldApplyTranscript(
                screenIsNote: false,
                isParsing: false,
                isSaving: false
            )
        )
        #expect(
            !NoteInteractionGate.shouldApplyTranscript(
                screenIsNote: true,
                isParsing: true,
                isSaving: false
            )
        )
        #expect(
            !NoteInteractionGate.shouldApplyTranscript(
                screenIsNote: true,
                isParsing: false,
                isSaving: true
            )
        )
        #expect(
            NoteInteractionGate.shouldApplyTranscript(
                screenIsNote: true,
                isParsing: false,
                isSaving: false
            )
        )
    }
}
