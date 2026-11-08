import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 voice-delete: deterministic intent discrimination + match policy.
/// No GUI, no network, no provider access — pure contract tests.
struct DeleteIntentTests {

    static func makeParser(now: Date) -> EventParser {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 13
        components.hour = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let now = calendar.date(from: components)!
        return EventParser(calendar: calendar, nowProvider: { now })
    }

    static var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 13
        components.hour = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar.date(from: components)!
    }

    // MARK: - Routing: delete cues

    @Test func leadingDeleteCueClassifiesAsDelete() {
        let result = DeleteIntentDiscriminator.classify(
            "Delete my dentist appointment tomorrow",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .deleteQuery(let query) = result else {
            Issue.record("expected deleteQuery, got \(result)")
            return
        }
        #expect(query.title == "Dentist appointment")
        #expect(query.dateComponents?.day == 14)
        #expect(query.dateComponents?.month == 11)
    }

    @Test func leadingRemoveCueClassifiesAsDelete() {
        let result = DeleteIntentDiscriminator.classify(
            "remove my lunch on Friday",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .deleteQuery(let query) = result else {
            Issue.record("expected deleteQuery, got \(result)")
            return
        }
        #expect(query.title.lowercased() == "lunch")
    }

    @Test func pleasePrefixStillClassifiesAsDelete() {
        let result = DeleteIntentDiscriminator.classify(
            "Please delete the team meeting tomorrow at 3pm",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .deleteQuery(let query) = result else {
            Issue.record("expected deleteQuery, got \(result)")
            return
        }
        #expect(query.title.lowercased() == "team meeting")
        #expect(query.timeComponents?.hour == 15)
    }

    @Test func bareDeleteCueAsksWhichEvent() {
        let result = DeleteIntentDiscriminator.classify(
            "delete",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        guard case .needsClarification = result else {
            Issue.record("expected needsClarification, got \(result)")
            return
        }
    }

    // MARK: - Routing: non-delete controls (injection safety)

    @Test func addRequestQuotingDeleteIsNotDelete() {
        let result = DeleteIntentDiscriminator.classify(
            "Add an event called delete my dentist appointment tomorrow",
            parser: Self.makeParser(now: Self.now), now: Self.now)
        #expect(DeleteIntentDiscriminator.classify(
            "Add an event called delete my dentist appointment tomorrow",
            parser: Self.makeParser(now: Self.now), now: Self.now) == result)
        guard case .notDelete = result else {
            Issue.record("injected delete inside an add request must not classify as delete")
            return
        }
    }

    @Test func midSentenceDeleteWordIsNotDelete() {
        for phrase in [
            "Lunch with Sam, and remember to delete the old invite",
            "Dentist appointment tomorrow (delete old one later) at 2pm"
        ] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .notDelete = result else {
                Issue.record("mid-sentence delete must not classify as delete: \(phrase)")
                return
            }
        }
    }

    @Test func leadingNegationIsNeverDelete() {
        for phrase in ["don't delete my dentist appointment", "do not delete my lunch"] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .notDelete = result else {
                Issue.record("negated delete must not classify as delete: \(phrase)")
                return
            }
        }
    }

    @Test func ordinaryAddsStayAdds() {
        for phrase in [
            "Coffee tomorrow at 10 AM",
            "Dinner with Sam Friday at 7 PM",
            "add gym session tomorrow at 6pm"
        ] {
            let result = DeleteIntentDiscriminator.classify(
                phrase, parser: Self.makeParser(now: Self.now), now: Self.now)
            guard case .notDelete = result else {
                Issue.record("ordinary add must not classify as delete: \(phrase)")
                return
            }
        }
    }

    // MARK: - Match policy boundaries

    @Test func titleMatchIsExactNeverFuzzy() {
        #expect(DeleteMatchPolicy.titleMatches(query: "Dentist appointment", candidate: "dentist appointment"))
        #expect(DeleteMatchPolicy.titleMatches(query: "Dentist appointment", candidate: " Dentist  Appointment "))
        #expect(!DeleteMatchPolicy.titleMatches(query: "dentist", candidate: "Dentist appointment"))
        #expect(!DeleteMatchPolicy.titleMatches(query: "Dentist appointment", candidate: "Dentist appointment with Dr. Patel"))
        #expect(!DeleteMatchPolicy.titleMatches(query: "", candidate: "Dentist appointment"))
    }

    @Test func timeMatchRequiresExactHourMinuteWhenStated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 14; comps.hour = 14; comps.minute = 0
        let twoPM = calendar.date(from: comps)!

        var stated = DateComponents(); stated.hour = 14; stated.minute = 0
        #expect(DeleteMatchPolicy.timeMatches(expected: stated, candidateStart: twoPM, calendar: calendar))
        var wrongMinute = DateComponents(); wrongMinute.hour = 14; wrongMinute.minute = 30
        #expect(!DeleteMatchPolicy.timeMatches(expected: wrongMinute, candidateStart: twoPM, calendar: calendar))
        // No time stated → any time matches.
        #expect(DeleteMatchPolicy.timeMatches(expected: nil, candidateStart: twoPM, calendar: calendar))
    }

    @Test func windowForExplicitDayIsThatCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        var day = DateComponents(); day.year = 2026; day.month = 11; day.day = 14
        let window = DeleteMatchPolicy.window(dateComponents: day, calendar: calendar, now: Self.now)
        #expect(window != nil)
        #expect(calendar.isDate(window!.start, inSameDayAs: calendar.date(from: day)!))
        #expect(calendar.dateComponents([.day], from: window!.start, to: window!.end).day == 1)
    }

    @Test func windowForMissingDayIsBoundedHorizon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let window = DeleteMatchPolicy.window(dateComponents: nil, calendar: calendar, now: Self.now)
        #expect(window != nil)
        #expect(calendar.isDate(window!.start, inSameDayAs: Self.now))
        #expect(window!.end.timeIntervalSince(window!.start) == Double(14 * 24 * 3600))
    }

    @Test func windowRejectsNonexistentDate() {
        var calendar = Calendar(identifier: .gregorian)
        var day = DateComponents(); day.year = 2026; day.month = 2; day.day = 30
        #expect(DeleteMatchPolicy.window(dateComponents: day, calendar: calendar, now: Self.now) == nil)
    }
}
