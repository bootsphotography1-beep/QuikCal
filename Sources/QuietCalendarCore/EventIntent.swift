import Foundation

/// What a parser believes the user asked for, before deterministic defaults are applied.
///
/// `date` is only set when the user *explicitly* stated a day. A missing date is
/// resolved against the local clock: today when the time is still ahead, otherwise
/// tomorrow. An explicit past date is never shifted — it asks for clarification.
public struct EventIntent: Sendable, Equatable {
    public var title: String
    public var date: DateComponents?
    public var time: DateComponents?
    public var durationSeconds: Int?
    public var location: String?
    /// User-provided description/notes (0.3.17): extra detail from the
    /// user's own words, carried separately from the concise title. nil =
    /// none stated (never invented).
    public var notes: String?
    /// Reminder lead time in minutes before the event start, when the user
    /// explicitly asked for one ("remind me 15 minutes before"). nil = none.
    public var reminderLeadMinutes: Int?
    /// True when an explicit clock time was RECOGNIZED but its meridiem was
    /// not ("six o'clock", "3:00", "at 3"): `time` carries the hour as
    /// spoken (1–12) and the resolver asks am/pm with real candidates —
    /// never silently assumes. (0.3.22)
    public var timeNeedsAMPMConfirmation: Bool
    /// True when the OWNER-APPROVED daytime rule (2026-11-08) inferred the
    /// meridiem of a spoken clock ("three o'clock" → 3pm): the draft
    /// resolves normally, but the review surface labels the inference so
    /// the user can check and edit it.
    public var timeInferredDaytime: Bool
    /// True for a digit-only cued bare hour such as "at 2". It remains
    /// am/pm-ambiguous and uses the compact legacy clarification wording.
    public var timeIsNumericBareHour: Bool

    public init(
        title: String,
        date: DateComponents? = nil,
        time: DateComponents? = nil,
        durationSeconds: Int? = nil,
        location: String? = nil,
        notes: String? = nil,
        reminderLeadMinutes: Int? = nil,
        timeNeedsAMPMConfirmation: Bool = false,
        timeInferredDaytime: Bool = false,
        timeIsNumericBareHour: Bool = false
    ) {
        self.title = title
        self.date = date
        self.time = time
        self.durationSeconds = durationSeconds
        self.location = location
        self.notes = notes
        self.reminderLeadMinutes = reminderLeadMinutes
        self.timeNeedsAMPMConfirmation = timeNeedsAMPMConfirmation
        self.timeInferredDaytime = timeInferredDaytime
        self.timeIsNumericBareHour = timeIsNumericBareHour
    }
}

/// Turns an `EventIntent` into a concrete event draft using only the local clock/calendar.
///
/// This is the single place that applies the defaulting rules, so the offline parser and
/// the local model share identical date/duration behaviour.
public struct EventDraftResolver: Sendable {
    public static let defaultDurationSeconds = 3600
    public static let minimumDurationSeconds = 5 * 60
    public static let maximumDurationSeconds = 12 * 3600
    /// Provider limit for a reminder lead time, in minutes before the event
    /// start: Google Calendar allows 0–40,320 (4 weeks); EventKit documents
    /// no tighter bound, so the same cap applies for parity. Larger values
    /// are rejected honestly (clarification), never silently clamped.
    public static let maximumReminderLeadMinutes = 40_320
    /// A start this close to "now" is treated as the current minute rather than the past.
    public static let pastGraceSeconds: TimeInterval = 5 * 60

    public let calendar: Calendar
    public let defaultDurationSeconds: Int
    public let pastGraceSeconds: TimeInterval

    public init(
        calendar: Calendar,
        defaultDurationSeconds: Int = EventDraftResolver.defaultDurationSeconds,
        pastGraceSeconds: TimeInterval = EventDraftResolver.pastGraceSeconds
    ) {
        self.calendar = calendar
        self.defaultDurationSeconds = defaultDurationSeconds
        self.pastGraceSeconds = pastGraceSeconds
    }

    public func resolve(_ intent: EventIntent, now: Date) -> ParseResult {
        guard let time = intent.time, let hour = time.hour, let minute = time.minute else {
            return .needsClarification("Please include a time (e.g. 2pm, 14:00, noon).")
        }
        // Recognized but meridiem-ambiguous clock ("three o'clock", "3:00",
        // "at 3"): ask with the actual hour — never silently am or pm.
        if intent.timeNeedsAMPMConfirmation {
            let phrase = intent.timeIsNumericBareHour
                ? String(((hour - 1) % 12) + 1)
                : Self.ampmAskPhrase(hour: hour, minute: minute)
            return .needsClarification("Did you mean \(phrase)am or \(phrase)pm? Pick one below.")
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return .needsClarification("That time is not valid. Use a time like 2pm, 14:00 or noon.")
        }

        let start: Date
        if let day = intent.date, let year = day.year, let month = day.month, let dayOfMonth = day.day {
            // Explicit date: build it, validate it, and refuse to quietly move it.
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = dayOfMonth
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let candidate = calendar.date(from: comps),
                  calendar.component(.year, from: candidate) == year,
                  calendar.component(.month, from: candidate) == month,
                  calendar.component(.day, from: candidate) == dayOfMonth
            else {
                return .needsClarification("That date does not exist. Choose a valid date.")
            }
            if candidate < now.addingTimeInterval(-pastGraceSeconds) {
                return .needsClarification("That date and time have already passed. Choose a future date or time.")
            }
            start = candidate
        } else {
            // No date stated: today if the time is still ahead, otherwise tomorrow.
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard var candidate = calendar.date(from: comps) else {
                return .failed("Could not construct a date from that time.")
            }
            if candidate < now {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return .failed("Could not construct a date from that time.")
                }
                candidate = nextDay
            }
            start = candidate
        }

        let requested = intent.durationSeconds ?? defaultDurationSeconds
        let duration = Self.normalizedDuration(requested)
        guard let end = calendar.date(byAdding: .second, value: duration, to: start) else {
            return .failed("Could not construct the event end time.")
        }

        // Reminder lead time: attaches to the event; start/end are untouched.
        // Defense in depth — the parser already clarifies out-of-range asks.
        if let requestedReminder = intent.reminderLeadMinutes,
           !(0...Self.maximumReminderLeadMinutes).contains(requestedReminder) {
            return .needsClarification(
                "That reminder is too far ahead — reminders can be at most 4 weeks (28 days) before an event. Try a shorter time like “remind me 2 hours before”.")
        }

        let title = intent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = intent.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let notes = intent.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return .event(
            EventDraft(
                title: title.isEmpty ? "Event" : title,
                start: start,
                end: end,
                location: location,
                notes: notes,
                reminderLeadMinutes: intent.reminderLeadMinutes
            )
        )
    }

    /// Keeps a duration inside a sane range instead of rejecting the whole request.
    public static func normalizedDuration(_ seconds: Int) -> Int {
        guard seconds > 0 else { return defaultDurationSeconds }
        if seconds < minimumDurationSeconds { return minimumDurationSeconds }
        if seconds > maximumDurationSeconds { return maximumDurationSeconds }
        return seconds
    }

    /// Display phrase for a meridiem-ambiguous clock ask ("3:00").
    /// The hour arrives as spoken (1–12) from the parser's ambiguous path.
    public static func ampmAskPhrase(hour: Int, minute: Int) -> String {
        let h12 = ((hour - 1) % 12) + 1
        return "\(h12):\(String(format: "%02d", minute))"
    }
}

extension String {
    public var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
