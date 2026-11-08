import Testing
import Foundation
@testable import QuietCalendarCore

struct ParserTests {
    // Fixed "now": Wednesday 2026-11-04 09:00 New York.
    static let tz = TimeZone(identifier: "America/New_York")!
    static let now: Date = makeNow(hour: 9, minute: 0)

    static func makeNow(hour: Int, minute: Int, day: Int = 4) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: c)!
    }

    func makeParser(now: Date = ParserTests.now) -> EventParser {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.tz
        return EventParser(calendar: cal, nowProvider: { now })
    }

    func event(_ result: ParseResult) -> EventDraft? {
        if case .event(let draft) = result { return draft }
        return nil
    }

    // MARK: Basics

    @Test func todayAt2pmForHour() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting today at 2pm for an hour")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Meeting")
        #expect(p.calendar.component(.hour, from: d.start) == 14)
        #expect(p.calendar.component(.minute, from: d.start) == 0)
        #expect(d.end.timeIntervalSince(d.start) == 3600)
    }

    @Test func tomorrowNoon40Min() {
        let p = makeParser()
        guard let d = event(p.parse("Lunch tomorrow noon for 40 minutes")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Lunch")
        #expect(p.calendar.component(.hour, from: d.start) == 12)
        #expect(d.end.timeIntervalSince(d.start) == 2400)
        let expectedDay = p.calendar.date(byAdding: .day, value: 1, to: p.calendar.startOfDay(for: Self.now))!
        #expect(p.calendar.isDate(d.start, inSameDayAs: expectedDay))
    }

    @Test func namedWeekday() {
        let p = makeParser()
        guard let d = event(p.parse("Standup Friday at 10am")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Standup")
        #expect(p.calendar.component(.weekday, from: d.start) == 6)
        #expect(p.calendar.component(.hour, from: d.start) == 10)
    }

    @Test func weekdayAbbreviation() {
        let p = makeParser()
        guard let d = event(p.parse("Standup Fri at 10am")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.weekday, from: d.start) == 6)
    }

    @Test func nextSameWeekdayMovesAWeek() {
        // Now is Wednesday. "next Wednesday" should not resolve to today.
        let p = makeParser()
        guard let d = event(p.parse("Review next Wednesday at 10am")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.day, from: d.start) == 11)
    }

    @Test func twelveAmPm() {
        let p = makeParser()
        guard let d1 = event(p.parse("A tomorrow at 12am")),
              let d2 = event(p.parse("B today at 12pm")) else {
            Issue.record("expected events"); return
        }
        #expect(p.calendar.component(.hour, from: d1.start) == 0)
        #expect(p.calendar.component(.hour, from: d2.start) == 12)
    }

    // MARK: Defaults

    @Test func defaultNoDateNoonBeforeNoonIsToday() {
        let p = makeParser(now: Self.makeNow(hour: 9, minute: 0))
        guard let d = event(p.parse("Meeting at noon")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.isDate(d.start, inSameDayAs: Self.now))
        #expect(p.calendar.component(.hour, from: d.start) == 12)
        #expect(d.end.timeIntervalSince(d.start) == Double(EventDraftResolver.defaultDurationSeconds))
    }

    @Test func defaultNoDateNoonAfterNoonIsTomorrow() {
        let afternoon = Self.makeNow(hour: 13, minute: 0)
        let p = makeParser(now: afternoon)
        guard let d = event(p.parse("Meeting at noon")) else {
            Issue.record("expected event"); return
        }
        #expect(!p.calendar.isDate(d.start, inSameDayAs: afternoon))
        #expect(p.calendar.component(.day, from: d.start) == 5)
        #expect(p.calendar.component(.hour, from: d.start) == 12)
    }

    @Test func defaultDurationIsOneHour() {
        let p = makeParser()
        guard let d = event(p.parse("Sync tomorrow at 3pm")) else {
            Issue.record("expected event"); return
        }
        #expect(d.end.timeIntervalSince(d.start) == 3600)
    }

    @Test func explicitPastDateClarifies() {
        let p = makeParser()
        let result = p.parse("Meeting 2026-11-01 at 2pm")
        guard case .needsClarification(let message) = result else {
            Issue.record("expected clarification: \(result)"); return
        }
        #expect(message.lowercased().contains("passed"))
    }

    // MARK: Times

    @Test func twoThirtyPm() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting today at 2:30pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.hour, from: d.start) == 14)
        #expect(p.calendar.component(.minute, from: d.start) == 30)
    }

    @Test func twoThirtyPmSpaced() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting today at 2:30 pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.hour, from: d.start) == 14)
        #expect(p.calendar.component(.minute, from: d.start) == 30)
    }

    @Test func twelveThirtyAmPm() {
        let p = makeParser()
        guard let d1 = event(p.parse("A tomorrow at 12:30am")),
              let d2 = event(p.parse("B today at 12:30pm")) else {
            Issue.record("expected events"); return
        }
        #expect(p.calendar.component(.hour, from: d1.start) == 0)
        #expect(p.calendar.component(.minute, from: d1.start) == 30)
        #expect(p.calendar.component(.hour, from: d2.start) == 12)
        #expect(p.calendar.component(.minute, from: d2.start) == 30)
    }

    @Test func afternoonNotNoon() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting today in the afternoon at 2pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.hour, from: d.start) == 14)
        #expect(p.calendar.component(.minute, from: d.start) == 0)
    }

    @Test func missingTimeClarifies() {
        let p = makeParser()
        guard case .needsClarification(let message) = p.parse("Meeting tomorrow") else {
            Issue.record("expected clarification"); return
        }
        #expect(message.lowercased().contains("time"))
    }

    @Test func ambiguousBareHourClarifies() {
        let p = makeParser()
        guard case .needsClarification(let message) = p.parse("Meeting today at 2") else {
            Issue.record("expected clarification"); return
        }
        #expect(message.contains("am or 2pm"))
    }

    @Test func pastTimeClarifies() {
        let p = makeParser()
        guard case .needsClarification = p.parse("Meeting today at 8am") else {
            Issue.record("expected clarification"); return
        }
    }

    // MARK: Dates

    @Test func datedEventISO() {
        let p = makeParser()
        guard let d = event(p.parse("Trip 2026-12-25 at 9am")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.month, from: d.start) == 12)
        #expect(p.calendar.component(.day, from: d.start) == 25)
    }

    @Test func monthDay() {
        let p = makeParser()
        guard let d = event(p.parse("Dinner Dec 5 at 7pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.month, from: d.start) == 12)
        #expect(p.calendar.component(.day, from: d.start) == 5)
        #expect(p.calendar.component(.hour, from: d.start) == 19)
    }

    @Test func dayMonth() {
        let p = makeParser()
        guard let d = event(p.parse("Dinner 5 Dec at 7pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.month, from: d.start) == 12)
        #expect(p.calendar.component(.day, from: d.start) == 5)
    }

    @Test func nonexistentDateClarifies() {
        let p = makeParser()
        guard case .needsClarification(let message) = p.parse("Dinner Feb 30 at 7pm") else {
            Issue.record("expected clarification"); return
        }
        #expect(message.lowercased().contains("exist"))
    }

    @Test func ambiguousNumericDateClarifies() {
        let p = makeParser()
        guard case .needsClarification = p.parse("Meeting 05/06 at 2pm") else {
            Issue.record("expected clarification"); return
        }
    }

    @Test func unambiguousNumericDate() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting 13/05 at 2pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.month, from: d.start) == 5)
        #expect(p.calendar.component(.day, from: d.start) == 13)
    }

    @Test func dayAfterTomorrow() {
        let p = makeParser()
        guard let d = event(p.parse("Pickup the day after tomorrow at 4pm")) else {
            Issue.record("expected event"); return
        }
        #expect(p.calendar.component(.day, from: d.start) == 6)
    }

    @Test func unresolvedRelativeDateClarifies() {
        let p = makeParser()
        guard case .needsClarification(let message) = p.parse("Planning next week at 2pm") else {
            Issue.record("expected clarification"); return
        }
        #expect(message.contains("next week"))
    }

    @Test func relativeStartClarifies() {
        let p = makeParser()
        guard case .needsClarification(let message) = p.parse("Call Sam in 20 minutes") else {
            Issue.record("expected clarification"); return
        }
        #expect(message.contains("Relative times"))
    }

    // MARK: Durations

    @Test func durationHalfHour() {
        let p = makeParser()
        guard let d = event(p.parse("Call today at 3pm for half an hour")) else {
            Issue.record("expected event"); return
        }
        #expect(d.end.timeIntervalSince(d.start) == 1800)
    }

    @Test func durationBare40Minutes() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting today at 2pm 40 minutes")) else {
            Issue.record("expected event"); return
        }
        #expect(d.end.timeIntervalSince(d.start) == 2400)
        #expect(d.title == "Meeting")
    }

    @Test func durationHourAndMinutes() {
        let p = makeParser()
        guard let d = event(p.parse("Workshop tomorrow at 1pm for 1 hour 30 minutes")) else {
            Issue.record("expected event"); return
        }
        #expect(d.end.timeIntervalSince(d.start) == 5400)
    }

    @Test func durationAnHourAndAHalf() {
        let p = makeParser()
        guard let d = event(p.parse("Review tomorrow at 9am for an hour and a half")) else {
            Issue.record("expected event"); return
        }
        #expect(d.end.timeIntervalSince(d.start) == 5400)
    }

    // MARK: Location

    @Test func locationExtraction() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting at noon in Sturm 320")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Meeting")
        #expect(d.location == "Sturm 320")
        #expect(p.calendar.component(.hour, from: d.start) == 12)
    }

    @Test func afternoonIsNotALocation() {
        let p = makeParser()
        guard let d = event(p.parse("Meeting in the afternoon at 2pm")) else {
            Issue.record("expected event"); return
        }
        #expect(d.location == nil)
    }

    @Test func locationAfterAt() {
        let p = makeParser()
        guard let d = event(p.parse("Lunch tomorrow at 1pm at Joe's Diner")) else {
            Issue.record("expected event"); return
        }
        #expect(d.location == "Joe's Diner")
        #expect(d.title == "Lunch")
    }

    // MARK: Titles

    @Test func saferTitleCleanup() {
        let p = makeParser()
        guard let d = event(p.parse("Call mom for details today at 2pm")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Call mom for details")
    }

    @Test func imperativePrefixRemoved() {
        let p = makeParser()
        guard let d = event(p.parse("Add a meeting tomorrow at 2pm")) else {
            Issue.record("expected event"); return
        }
        // 0.3.17: titles are tidied + capitalized for the review card.
        #expect(d.title == "Meeting")
    }

    @Test func emptyTitleBecomesEvent() {
        let p = makeParser()
        guard let d = event(p.parse("tomorrow at 2pm")) else {
            Issue.record("expected event"); return
        }
        #expect(d.title == "Event")
    }

    @Test func emptyInputFails() {
        let p = makeParser()
        guard case .failed = p.parse("   ") else {
            Issue.record("expected failure"); return
        }
    }
}
