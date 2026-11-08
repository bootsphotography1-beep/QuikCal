import Foundation

public struct Event: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.createdAt = createdAt
    }
}

public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    /// User-provided event description/notes (0.3.17): the useful extra
    /// detail from the user's own words that did not belong in the concise
    /// title. nil/empty = none stated — never invented filler. Persisted to
    /// EventKit `EKEvent.notes` and Google `description` as reviewed.
    public var notes: String?
    /// User-requested reminder lead time in minutes BEFORE the event start.
    /// nil = no reminder requested (provider default reminders untouched).
    /// The reminder attaches to the event — start/end are never shifted.
    public var reminderLeadMinutes: Int?

    public init(title: String, start: Date, end: Date, location: String? = nil, notes: String? = nil, reminderLeadMinutes: Int? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.reminderLeadMinutes = reminderLeadMinutes
    }
}

public enum ParseResult: Sendable, Equatable {
    case event(EventDraft)
    case needsClarification(String)
    case failed(String)
}