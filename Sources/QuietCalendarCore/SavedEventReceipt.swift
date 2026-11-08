import Foundation

/// Which provider a saved event was persisted to. Mirrors the
/// single-destination rule (EventKit XOR Google) enforced by
/// `DestinationPolicy` — one Add never writes to both.
public enum SavedEventProvider: String, Sendable, Equatable, Codable {
    case eventKit
    case google
}

/// Honest "saved" receipt for ONE successfully persisted event — the UI's
/// confirmation that a real write happened, never a pre-save preview.
///
/// Built ONLY from a confirmed write result: the provider's returned event
/// ID (and, for Google, the official `htmlLink` returned by the insert
/// response — never a guessed URL). A draft that failed, stayed uncertain
/// (`commitUncertain`), or only reached the confirmation screen NEVER
/// produces a receipt. Partial batch failures produce receipts only for the
/// events that actually persisted — a partial failure is never reported as
/// "all saved".
public struct SavedEventReceipt: Identifiable, Sendable, Equatable, Codable {
    /// Fresh receipt identity (not the provider's event ID).
    public var id: UUID
    /// The confirmation draft this event came from, when known.
    public var draftID: UUID?
    public var provider: SavedEventProvider
    /// Provider event identifier (EventKit `calendarItemIdentifier` /
    /// Google event id) — proof of the persisted write.
    public var eventID: String
    /// Google's own `htmlLink` from the insert response; nil for EventKit
    /// (EventKit has no equivalent public web URL — no guessed links).
    public var eventURL: String?
    public var calendarID: String
    public var calendarSummary: String?
    public var title: String
    /// The event's actual start/end — unchanged by the reminder (a reminder
    /// attaches to the event; it never shifts the start).
    public var start: Date
    public var end: Date
    public var location: String?
    /// User-provided description/notes as actually saved (0.3.17) — the
    /// receipt reflects the persisted values, never a pre-save preview.
    public var notes: String?
    /// User-requested reminder lead time in minutes before the event start;
    /// nil when no reminder was requested (provider defaults untouched).
    public var reminderLeadMinutes: Int?
    /// When the confirmed write result was received locally.
    public var savedAt: Date

    public init(
        id: UUID = UUID(),
        draftID: UUID? = nil,
        provider: SavedEventProvider,
        eventID: String,
        eventURL: String? = nil,
        calendarID: String,
        calendarSummary: String? = nil,
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil,
        reminderLeadMinutes: Int? = nil,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.draftID = draftID
        self.provider = provider
        self.eventID = eventID
        self.eventURL = eventURL
        self.calendarID = calendarID
        self.calendarSummary = calendarSummary
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.reminderLeadMinutes = reminderLeadMinutes
        self.savedAt = savedAt
    }
}
