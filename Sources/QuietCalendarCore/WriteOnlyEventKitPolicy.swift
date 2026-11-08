import Foundation

/// Honest EventKit WRITE-ONLY semantics (2026-11-07 independent-review
/// integration). Under a write-only grant EventKit permits NO event reads
/// and may refuse `calendar(withIdentifier:)` even though the DEFAULT
/// calendar for new events is authorized and writable. Two consequences,
/// both pinned by tests:
///
/// 1. WRITE RESOLUTION: when the identifier lookup fails under
///    write-only, the write path resolves the ACTUAL
///    `defaultCalendarForNewEvents` AT WRITE TIME — accepted ONLY when
///    its identifier matches the calendar the user chose (identifier
///    safety: never silently write to a different calendar).
/// 2. DUPLICATE DETECTION: with no read access an exact-match probe can
///    verify NOTHING. "No duplicate found" must never be presented as a
///    verification under write-only — the capability is `unverifiable`
///    and callers must report that honestly instead.
public enum DuplicateCheckCapability: Sendable, Equatable {
    /// Event reads are permitted — an exact-match probe is a real verification.
    case verified
    /// No event reads are permitted — a probe result means "unable to
    /// check", NEVER "verified no duplicate".
    case unverifiable
}

/// Pure policy for the EventKit write-only grant (no EventKit import —
/// fully unit-testable; `CalendarService` wires the real store into it).
public enum WriteOnlyEventKitPolicy: Sendable {
    /// Duplicate-exact-match capability from read permission alone.
    public static func duplicateCheckCapability(canReadEvents: Bool) -> DuplicateCheckCapability {
        canReadEvents ? .verified : .unverifiable
    }

    /// Whether the write-time default calendar may stand in for the user's
    /// chosen calendar under write-only: the identifiers must MATCH and the
    /// default calendar must be writable. A mismatch (or a missing /
    /// read-only default) is REFUSED — QuikCal never silently writes to a
    /// different calendar than the one the user chose.
    public static func defaultCalendarFallbackIsSafe(
        defaultCalendarID: String?,
        chosenCalendarID: String,
        defaultCalendarIsWritable: Bool
    ) -> Bool {
        guard defaultCalendarIsWritable, let defaultCalendarID else { return false }
        return defaultCalendarID == chosenCalendarID
    }
}
