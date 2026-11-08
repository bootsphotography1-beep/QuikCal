import Testing
import Foundation
@testable import QuietCalendarCore

struct LocalModelTests {
    static let tz = TimeZone(identifier: "America/New_York")!
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 4; c.hour = 9; c.minute = 0; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: c)!
    }()

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    func validate(_ json: String) throws -> EventIntent {
        try StrictIntentJSON.intent(fromJSONText: json, now: Self.now, calendar: Self.calendar)
    }

    // MARK: Valid output

    @Test func acceptsCompleteValidObject() throws {
        let intent = try validate("""
        {"title":"Meeting","date":"2026-11-05","start_time":"12:00","duration_minutes":45,"location":"Sturm 320"}
        """)
        #expect(intent.title == "Meeting")
        #expect(intent.date?.year == 2026)
        #expect(intent.date?.month == 11)
        #expect(intent.date?.day == 5)
        #expect(intent.time?.hour == 12)
        #expect(intent.time?.minute == 0)
        #expect(intent.durationSeconds == 45 * 60)
        #expect(intent.location == "Sturm 320")
    }

    @Test func acceptsNullFields() throws {
        let intent = try validate("""
        {"title":"Standup","date":null,"start_time":null,"duration_minutes":null,"location":null}
        """)
        #expect(intent.date == nil)
        #expect(intent.time == nil)
        #expect(intent.durationSeconds == nil)
        #expect(intent.location == nil)
    }

    // MARK: Malformed JSON

    @Test func rejectsNonJSON() {
        #expect(throws: LocalModelFailure.self) { try validate("tomorrow at noon") }
    }

    @Test func rejectsJSONArray() {
        #expect(throws: LocalModelFailure.self) { try validate("[]") }
    }

    @Test func rejectsTruncatedJSON() {
        #expect(throws: LocalModelFailure.self) { try validate(#"{"title":"Meeting""#) }
    }

    @Test func rejectsEmptyOutput() {
        #expect(throws: LocalModelFailure.self) { try validate("   ") }
    }

    // MARK: Schema violations

    @Test func rejectsUnknownField() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","attendees":["Sam"]}"#)
        }
    }

    @Test func rejectsMissingTitle() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"start_time":"12:00"}"#)
        }
    }

    @Test func rejectsEmptyTitle() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"   ","start_time":"12:00"}"#)
        }
    }

    @Test func rejectsTitleWrongType() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":42,"start_time":"12:00"}"#)
        }
    }

    // MARK: Dates

    @Test func rejectsNonISO8601Date() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","date":"11/05/2026","start_time":"12:00"}"#)
        }
    }

    @Test func rejectsImpossibleDate() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","date":"2026-02-30","start_time":"12:00"}"#)
        }
    }

    @Test func rejectsDateTooFarAway() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","date":"2400-01-01","start_time":"12:00"}"#)
        }
    }

    @Test func rejectsDateWrongType() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","date":20261105,"start_time":"12:00"}"#)
        }
    }

    // MARK: Times

    @Test func rejectsHour24() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"24:00"}"#)
        }
    }

    @Test func rejectsMinute60() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:60"}"#)
        }
    }

    @Test func rejectsLooseTimeFormat() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"9:00"}"#)
        }
    }

    @Test func rejectsAmbiguousAmPmTime() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"2pm"}"#)
        }
    }

    // MARK: Durations

    @Test func rejectsStringDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":"45"}"#)
        }
    }

    @Test func rejectsFractionalDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":30.5}"#)
        }
    }

    @Test func rejectsBooleanDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":true}"#)
        }
    }

    @Test func rejectsZeroDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":0}"#)
        }
    }

    @Test func rejectsNegativeDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":-30}"#)
        }
    }

    @Test func rejectsOverlongDuration() {
        #expect(throws: LocalModelFailure.self) {
            try validate(#"{"title":"Meeting","start_time":"12:00","duration_minutes":721}"#)
        }
    }

}
