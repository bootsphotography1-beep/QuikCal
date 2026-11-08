import Foundation

/// A parsed delete request, derived deterministically from the recognized
/// (or typed) phrase. Carries the target title plus optional explicit
/// date/time criteria; the coordinator owns every decision after this.
public struct DeleteQuery: Sendable, Equatable {
    /// The full original phrase (kept for UI display, never re-parsed).
    public var rawPhrase: String
    /// Cleaned target title: delete cue, possessives/articles and
    /// date/time/location words removed by the shared parser grammar.
    public var title: String
    /// Explicit day criterion (nil = bounded upcoming window).
    public var dateComponents: DateComponents?
    /// Explicit clock-time criterion (nil = any time on the day).
    public var timeComponents: DateComponents?

    public init(
        rawPhrase: String,
        title: String,
        dateComponents: DateComponents?,
        timeComponents: DateComponents?
    ) {
        self.rawPhrase = rawPhrase
        self.title = title
        self.dateComponents = dateComponents
        self.timeComponents = timeComponents
    }
}

/// Cheap deterministic classification run BEFORE the add pipeline.
/// Safety contract:
/// - Only a LEADING imperative delete cue ("delete …", "remove …",
///   optionally after "please") classifies as delete.
/// - Leading negations ("don't delete …") are never deletes.
/// - A leading UNSUPPORTED destructive cue ("cancel …", "erase …",
///   "unschedule …", "get rid of …") is never silently routed to the add
///   pipeline — without this guard the parser would offer an accidental
///   ADD draft titled "cancel my dentist appointment" (review finding,
///   2026-11-07). It asks for a rephrase instead.
/// - A "delete" that appears anywhere else — quoted, injected inside an
///   add request, mid-sentence — is NOT a delete and falls through to the
///   unchanged add pipeline.
public enum DeleteIntentClassification: Sendable, Equatable {
    case notDelete
    case deleteQuery(DeleteQuery)
    case needsClarification(String)
}

public enum DeleteIntentDiscriminator: Sendable {

    /// Leading negation guard: "don't delete my event" must never mutate.
    private static let negationPattern =
        "^\\s*(?:please\\s+)?(?:do\\s*n[o']?t|dont|never|stop)\\b"

    /// Leading delete cue: an imperative verb at the very start.
    /// "delete" / "remove" (optionally preceded by "please").
    private static let cuePattern =
        "^\\s*(?:please\\s+)?(?:delete|remove)\\b\\s*(.*)$"

    /// Leading destructive cues QuikCal does NOT support as deletes.
    /// They must never fall through to the add pipeline, where the parser
    /// would offer an accidental ADD draft ("cancel my dentist
    /// appointment tomorrow at 2pm" → an add titled "cancel my dentist
    /// appointment"). Honest clarification instead; nothing is added.
    /// (Review hardening 2026-11-07.)
    private static let unsupportedDestructivePattern =
        "^\\s*(?:please\\s+)?(?:cancel|erase|unschedule|get\\s+rid\\s+of)\\b"

    /// Possessives/articles stripped from the target phrase after the cue.
    /// Capture group 1 = the remaining target text.
    private static let possessivePattern =
        "^\\s*(?:my|our|the|a|an|this|that|these|those)\\b\\s*(.*)$"

    public static func classify(_ text: String, parser: EventParser, now: Date) -> DeleteIntentClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notDelete }

        // A leading negation is never a delete — it falls through to the
        // add pipeline (which will ask for clarification on its own terms).
        if matches(pattern: negationPattern, in: trimmed) {
            return .notDelete
        }

        guard let cueMatch = firstMatch(pattern: cuePattern, in: trimmed),
              let remainderRange = captureGroup(cueMatch, text: trimmed) else {
            // Unsupported destructive phrasing must never reach the add
            // pipeline as an accidental add draft — ask for a rephrase.
            if matches(pattern: unsupportedDestructivePattern, in: trimmed) {
                return .needsClarification(DeleteFlowCopy.unsupportedDestructiveCue)
            }
            return .notDelete
        }
        var remainder = remainderRange
        // Strip up to two leading possessives/articles ("my dentist…").
        for _ in 0..<2 {
            if let possessive = firstMatch(pattern: possessivePattern, in: remainder),
               let stripped = captureGroup(possessive, text: remainder) {
                remainder = stripped
            } else {
                break
            }
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return .needsClarification(DeleteFlowCopy.whichEventClarification)
        }

        // Reuse the shared deterministic grammar so the delete query gets
        // exactly the same date/time/title extraction as an add.
        switch parser.extractIntent(remainder, now: now) {
        case .intent(let intent):
            let title = intent.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "Event" else {
                return .needsClarification(DeleteFlowCopy.whichEventClarification)
            }
            return .deleteQuery(
                DeleteQuery(
                    rawPhrase: trimmed,
                    title: title,
                    dateComponents: intent.date,
                    timeComponents: intent.time
                )
            )
        case .needsClarification(let message):
            return .needsClarification(message)
        case .failed(let message):
            return .needsClarification(message)
        }
    }

    // MARK: - Regex plumbing (case-insensitive, first match only)

    private static func matches(pattern: String, in text: String) -> Bool {
        firstMatch(pattern: pattern, in: text) != nil
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    /// Returns capture group 1 (the text after the matched prefix).
    private static func captureGroup(_ match: NSTextCheckingResult, text: String) -> String? {
        guard match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}

/// Shared user-facing copy for the delete flow (design nodes 24:99–24:132).
/// Pinned here so tests can lock the exact approved wording.
public enum DeleteFlowCopy: Sendable {
    public static let whichEventClarification =
        "Which event should I delete? Say its name and the day, like “delete my dentist appointment tomorrow”."
    /// Leading destructive phrasing QuikCal does not support as a delete.
    /// Honest rephrase request — crucially this also means NO add draft is
    /// created from the destructive phrase.
    public static let unsupportedDestructiveCue =
        "That sounds like a delete, but QuikCal only deletes events when you say “delete” or “remove”. Nothing was added. Try “delete my …” to review a delete, or start with “add” to add an event."
    public static let noMatch =
        "No matching event found. Check the event name or add a date, then try again."
    public static func recurringUnavailable(title: String) -> String {
        "“\(title)” is a recurring event. QuikCal can’t delete recurring events — review it in your calendar app."
    }
    public static let confirmTitle = "Delete this event?"
    public static let chooserTitle = "Which event?"
    public static let cancelButton = "Cancel"
    public static let deleteButton = "Delete event"
    public static let findingStatus = "Finding the event…"
    public static let deletingStatus = "Deleting…"
    public static func deletedRow(title: String, detail: String) -> String {
        "Event deleted — \(title), \(detail)"
    }
    public static let staleTarget =
        "The event changed since you reviewed it — nothing was deleted. Try again."
    public static let targetVanished =
        "The event can no longer be found — it may already be deleted or moved. Nothing was deleted."
    public static let stillPresentAfterDelete =
        "The calendar still reports this event — the delete may not have applied. Check your calendar before trying again."
    public static let deleteUncertain =
        "The delete result couldn’t be confirmed. Check your calendar before trying again — QuikCal won’t retry a delete on its own."
    public static let eventKitFullAccessNeeded =
        "Deleting needs full calendar access so QuikCal can find the event. Grant Full Access in System Settings → Privacy & Security → Calendars, then try again."
    public static let eventKitNoCalendar =
        "Choose a calendar before deleting — deletes target the calendar you selected."
    public static func googleNotReady(_ message: String) -> String {
        "Google delete is unavailable: \(message)"
    }
    public static let practiceRefusal =
        "Practice previews adds only — nothing is deleted here. Delete runs from the capture panel with your confirmation."
}
