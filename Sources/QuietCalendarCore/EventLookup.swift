import Foundation

/// Which provider lane a delete runs through. Exactly one is ever active
/// (EventKit XOR Google — the single-lane rule for adds applies to deletes).
public enum DeleteProvider: String, Sendable, Equatable {
    case eventKit
    case google
}

/// One concrete provider event considered for deletion. IDs are the
/// provider-stable identifiers (EventKit `eventIdentifier`, Google event
/// id) used for revalidation and the delete call.
public struct EventCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: DeleteProvider
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isRecurring: Bool
    public var location: String?
    /// Provider concurrency token, when the provider supports one (Google
    /// etag; nil for EventKit). Used for a conditional delete (If-Match)
    /// so a concurrently-changed event is rejected, not deleted.
    public var etag: String?

    public init(
        id: String,
        provider: DeleteProvider,
        calendarID: String,
        calendarTitle: String,
        title: String,
        start: Date,
        end: Date,
        isRecurring: Bool,
        location: String? = nil,
        etag: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isRecurring = isRecurring
        self.location = location
        self.etag = etag
    }
}

/// The immutable reviewed deletion target — a frozen snapshot of the exact
/// event the user saw and confirmed. The coordinator revalidates the live
/// provider state against this snapshot before any mutation.
public struct DeleteTarget: Sendable, Equatable {
    public var provider: DeleteProvider
    public var calendarID: String
    public var eventID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendarTitle: String

    public init(candidate: EventCandidate) {
        self.provider = candidate.provider
        self.calendarID = candidate.calendarID
        self.eventID = candidate.id
        self.title = candidate.title
        self.start = candidate.start
        self.end = candidate.end
        self.calendarTitle = candidate.calendarTitle
    }

    /// Identity + important metadata comparison against a fresh candidate.
    /// Any drift (moved, renamed, retimed, moved to another calendar)
    /// rejects the delete.
    public func matches(_ fresh: EventCandidate) -> Bool {
        provider == fresh.provider
            && calendarID == fresh.calendarID
            && eventID == fresh.id
            && title == fresh.title
            && start == fresh.start
            && end == fresh.end
    }
}

/// A provider lookup request: exact title + a bounded day window on ONE
/// calendar, with an optional explicit clock-time criterion.
public struct EventLookupQuery: Sendable, Equatable {
    public var title: String
    public var calendarID: String
    /// Display name of the target calendar (shown in the reviewed target).
    public var calendarTitle: String
    public var windowStart: Date
    public var windowEnd: Date
    /// Explicit hour/minute the user stated; nil = any time on the day.
    public var timeComponents: DateComponents?

    public init(
        title: String,
        calendarID: String,
        calendarTitle: String = "",
        windowStart: Date,
        windowEnd: Date,
        timeComponents: DateComponents? = nil
    ) {
        self.title = title
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.timeComponents = timeComponents
    }
}

/// Pure, deterministic matching policy for delete candidates.
///
/// - Title matching is EXACT (case-insensitive, whitespace-normalized).
///   Never fuzzy, never substring — "dentist" must not match
///   "Dentist appointment".
/// - The window is conservative: an explicit day → that calendar day;
///   no day stated → today through the next 14 days (bounded horizon,
///   never an open-ended scan).
public enum DeleteMatchPolicy: Sendable {
    public static let defaultHorizonDays = 14

    /// Exact title match, case-insensitive with normalized whitespace
    /// (interior runs collapse to single spaces). Never fuzzy, never
    /// substring.
    public static func titleMatches(query: String, candidate: String) -> Bool {
        let normalizedQuery = normalized(query)
        let normalizedCandidate = normalized(candidate)
        return !normalizedQuery.isEmpty
            && normalizedQuery.caseInsensitiveCompare(normalizedCandidate) == .orderedSame
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When the user stated a clock time, only candidates starting at that
    /// time (same hour/minute) match. No time stated → any time matches.
    public static func timeMatches(
        expected: DateComponents?,
        candidateStart: Date,
        calendar: Calendar
    ) -> Bool {
        guard let expected, let hour = expected.hour, let minute = expected.minute else {
            return true
        }
        return calendar.component(.hour, from: candidateStart) == hour
            && calendar.component(.minute, from: candidateStart) == minute
    }

    /// Resolves the day criterion into a bounded window.
    /// - Explicit components → that calendar day (validated; a nonexistent
    ///   date returns nil so the caller asks for clarification).
    /// - No date stated → today through `horizonDays` (bounded).
    public static func window(
        dateComponents: DateComponents?,
        calendar: Calendar,
        now: Date,
        horizonDays: Int = defaultHorizonDays
    ) -> (start: Date, end: Date)? {
        if let day = dateComponents, let year = day.year, let month = day.month, let dayOfMonth = day.day {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = dayOfMonth
            guard let start = calendar.date(from: comps),
                  calendar.component(.year, from: start) == year,
                  calendar.component(.month, from: start) == month,
                  calendar.component(.day, from: start) == dayOfMonth,
                  let end = calendar.date(byAdding: .day, value: 1, to: start)
            else {
                return nil
            }
            return (start, end)
        }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: start) else {
            return nil
        }
        return (start, end)
    }
}
