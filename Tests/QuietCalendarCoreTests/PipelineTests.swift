import Testing
import Foundation
@testable import QuietCalendarCore

@MainActor
struct PipelineTests {
    static let tz = TimeZone(identifier: "America/New_York")!
    static let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        components.hour = 9; components.minute = 0; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: components)!
    }()

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar
    }

    func makePipeline() -> ParsingPipeline {
        ParsingPipeline(
            parser: EventParser(calendar: Self.calendar, nowProvider: { Self.now }),
            calendar: Self.calendar)
    }

    @Test func deterministicResultResolvesOrdinaryEvent() async {
        let outcome = await makePipeline().parse("Meeting tomorrow at 3pm", now: Self.now)
        #expect(outcome.source == .builtIn)
        guard case .event(let draft) = outcome.result else {
            Issue.record("expected deterministic event")
            return
        }
        #expect(draft.title == "Meeting")
    }

    @Test func missingTimeRemainsClarification() async {
        let outcome = await makePipeline().parse("Coffee with Sam tomorrow", now: Self.now)
        guard case .needsClarification = outcome.result else {
            Issue.record("missing clock time must remain a clarification")
            return
        }
    }

    @Test func emptyInputFails() async {
        let outcome = await makePipeline().parse("   ", now: Self.now)
        guard case .failed = outcome.result else {
            Issue.record("empty input must fail")
            return
        }
    }

    @Test func ambiguousBareHourKeepsAmPmClarification() async {
        let outcome = await makePipeline().parse("Meeting today at 7", now: Self.now)
        guard case .needsClarification(let message) = outcome.result else {
            Issue.record("expected AM/PM clarification")
            return
        }
        #expect(message.contains("am") && message.contains("pm"))
        #expect(!outcome.ampmCandidates.isEmpty)
    }

    @Test func explicitMeridiemChoiceResolvesClock() async {
        let outcome = await makePipeline().parse("Meeting today at 2", now: Self.now, forcingPM: true)
        guard case .event(let draft) = outcome.result else {
            Issue.record("explicit PM choice should resolve the event")
            return
        }
        #expect(Self.calendar.component(.hour, from: draft.start) == 14)
    }

    @Test func ambiguousSlashDateRemainsClarification() async {
        let outcome = await makePipeline().parse("Meeting 05/06 at 2pm", now: Self.now)
        guard case .needsClarification(let message) = outcome.result else {
            Issue.record("expected ambiguous-date clarification")
            return
        }
        #expect(message.lowercased().contains("ambiguous"))
    }

    @Test func relativeTimeRemainsClarification() async {
        let outcome = await makePipeline().parse("Call Sam in 20 minutes", now: Self.now)
        guard case .needsClarification = outcome.result else {
            Issue.record("relative time must not be guessed")
            return
        }
    }

    @Test func explicitPastTimeRemainsClarification() async {
        let outcome = await makePipeline().parse("Meeting today at 8am", now: Self.now)
        #expect(outcome.source == .builtIn)
        guard case .needsClarification = outcome.result else {
            Issue.record("past explicit time must remain a clarification")
            return
        }
    }
}
