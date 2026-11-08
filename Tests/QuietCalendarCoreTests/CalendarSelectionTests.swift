import Testing
import Foundation
@testable import QuietCalendarCore

struct CalendarSelectionTests {
    let work = CalendarChoice(id: "cal-work", title: "Work", sourceTitle: "iCloud")
    let home = CalendarChoice(id: "cal-home", title: "Home", sourceTitle: "iCloud")

    @Test func noStoredSelection() {
        #expect(CalendarSelection.resolve(storedID: nil, choices: [work, home]) == .noneSelected)
        #expect(CalendarSelection.resolve(storedID: "", choices: [work, home]) == .noneSelected)
    }

    @Test func storedSelectionStillValid() {
        let state = CalendarSelection.resolve(storedID: "cal-home", choices: [work, home])
        #expect(state == .valid(home))
        #expect(state.needsAttention == false)
    }

    @Test func removedCalendarIsReportedMissing() {
        let state = CalendarSelection.resolve(storedID: "cal-deleted", choices: [work, home])
        #expect(state == .missing(storedID: "cal-deleted"))
        #expect(state.needsAttention == true)
        #expect(state.choice == nil)
    }

    @Test func readOnlyCalendarDisappearsFromChoices() {
        // A calendar that became read-only is filtered out of the writable list,
        // so a stored handle to it resolves as missing.
        let state = CalendarSelection.resolve(storedID: work.id, choices: [home])
        #expect(state == .missing(storedID: work.id))
    }
}
