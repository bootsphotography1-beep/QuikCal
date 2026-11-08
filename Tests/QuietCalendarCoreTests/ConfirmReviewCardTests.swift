import Testing
import Foundation
@testable import QuietCalendarCore

/// 2026-11-07 review pass — the default confirm REVIEW CARD contracts
/// (parent visual finding B): plain "Add this event?" question, readable
/// human date/time lines, and the explicit Yes/No wording. Pure logic only.
struct ConfirmReviewCardTests {

    /// Fixed time zone + calendar so the formatted lines are deterministic.
    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        guard let tz = TimeZone(identifier: "America/New_York") else { return calendar }
        calendar.timeZone = tz
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi
        return fixedCalendar().date(from: components) ?? Date()
    }

    // MARK: - The plain review question

    @Test func singleDraftAsksAddThisEvent() {
        #expect(ConfirmationReviewFormat.title(draftCount: 1) == "Add this event?")
        #expect(ConfirmationReviewFormat.title(draftCount: 0) == "Add this event?")
    }

    @Test func multiDraftAsksAddTheseEvents() {
        #expect(ConfirmationReviewFormat.title(draftCount: 2) == "Add these events?")
        #expect(ConfirmationReviewFormat.title(draftCount: 5) == "Add these events?")
    }

    // MARK: - Readable date/time lines

    @Test func sameDayLineIsCompactAndReadable() {
        let line = ConfirmationReviewFormat.dateTimeLine(
            start: date(2026, 11, 8, 14, 0),
            end: date(2026, 11, 8, 15, 0),
            calendar: fixedCalendar()
        )
        // "Sun 8 Nov · 2:00–3:00 PM" — day once, times en-dashed.
        #expect(line.contains("8 Nov"))
        #expect(line.contains("·"))
        #expect(line.contains("2:00"))
        #expect(line.contains("3:00"))
        #expect(line.contains("–"))
        // The day appears exactly once on a same-day event.
        #expect(line.components(separatedBy: "8 Nov").count == 2)
    }

    @Test func overnightLineShowsBothDays() {
        let line = ConfirmationReviewFormat.dateTimeLine(
            start: date(2026, 11, 8, 23, 0),
            end: date(2026, 11, 9, 1, 0),
            calendar: fixedCalendar()
        )
        #expect(line.contains("8 Nov"))
        #expect(line.contains("9 Nov"))
        #expect(line.contains("–"))
    }

    @Test func lineNeverContainsRawISOString() {
        let line = ConfirmationReviewFormat.dateTimeLine(
            start: date(2026, 11, 8, 14, 0),
            end: date(2026, 11, 8, 15, 0),
            calendar: fixedCalendar()
        )
        #expect(!line.contains("2026-"))
        #expect(!line.contains(":00:00"))
    }

    // MARK: - No/Yes wording pins (review-card actions)

    @Test func noAndYesRemainTheOnlyPrimaryActions() {
        // No = non-mutating rejection; Yes = the existing safe Add.
        #expect(ConfirmationRejectionPolicy.yesLabel(pendingCount: 1) == "Yes, add it")
        #expect(ConfirmationRejectionPolicy.yesLabel(pendingCount: 3) == "Yes, add 3")
        #expect(ConfirmationRejectionPolicy.mayReject(isSaving: true, anyDraftCommitted: false) == false)
        #expect(ConfirmationRejectionPolicy.mayReject(isSaving: false, anyDraftCommitted: true) == false)
        #expect(ConfirmationRejectionPolicy.rejectionWritesToCalendar == false)
    }
}
