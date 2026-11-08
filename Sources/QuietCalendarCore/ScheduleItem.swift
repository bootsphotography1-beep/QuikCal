import Foundation

/// A read-only projection of a calendar event for display in the popover and month window.
public struct ScheduleItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var calendarTitle: String
    public var isAllDay: Bool

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        calendarTitle: String,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
    }
}
