import Foundation

// MARK: - Confirmation rejection policy (P1 explicit Yes/No, 2026-11-07)
//
// "No" on the confirm screen is NON-MUTATING: it rejects the current draft
// generation (cancel any in-flight parse for it), writes NOTHING to any
// calendar sink, retains the original recognized transcript in the editable
// note field, and hints re-speak via the hold shortcut. It never pretends
// to cancel a write that already executed or is in flight (the caller
// refuses No while `isSaving`).
public enum ConfirmationRejectionPolicy: Sendable {
    public struct Outcome: Equatable, Sendable {
        /// The transcript restored into the editable note field ("" when
        /// nothing recognized was available).
        public var restoredTranscript: String
        /// Honest hint shown in the panel: edit or re-speak.
        public var hint: String

        public init(restoredTranscript: String, hint: String) {
            self.restoredTranscript = restoredTranscript
            self.hint = hint
        }
    }

    /// Pure rejection decision. `transcript` is the original recognized
    /// text (confirmation transcript, falling back to the note field);
    /// `shortcutName` names the ACTUAL hold key for the re-speak hint.
    /// 2026-11-07 parent fix: the editable note field sits ABOVE the
    /// status line, so the copy never claims a direction ("below") — and
    /// this is the normal rejection display, not an error state.
    public static func reject(transcript: String, shortcutName: String) -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = trimmed.isEmpty
            ? "Not added. Hold \(shortcutName) to speak, or type your note."
            : "Not added. Edit your text, or hold \(shortcutName) to speak again."
        return Outcome(restoredTranscript: trimmed, hint: hint)
    }

    /// A No is only honest when no write is in flight or committed for this
    /// confirmation — otherwise the button must be disabled (never a fake
    /// cancel of an executed calendar write).
    public static func mayReject(isSaving: Bool, anyDraftCommitted: Bool) -> Bool {
        !isSaving && !anyDraftCommitted
    }

    /// Yes-button labels — explicit confirmation wording.
    public static func yesLabel(pendingCount: Int) -> String {
        if pendingCount <= 0 { return "Yes, add it" }
        return pendingCount == 1 ? "Yes, add it" : "Yes, add \(pendingCount)"
    }

    /// No writes happen on the rejection path — asserted structurally by
    /// tests: the outcome carries no sink request, and the caller never
    /// reaches a write coordinator from it.
    public static var rejectionWritesToCalendar: Bool { false }
}

/// Pure review-card formatting for the confirmation screen (2026-11-07
/// review pass): readable, human date/time lines for the default review
/// card. Deterministic given a calendar + time zone (tests inject a fixed
/// zone); never locale-ambiguous inside a single line.
public enum ConfirmationReviewFormat: Sendable {
    /// "Fri 14 Nov · 2:00–3:00 PM" (same day) or
    /// "Fri 14 Nov, 2:00 PM – Sat 15 Nov, 3:00 PM" (spans midnight).
    public static func dateTimeLine(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> String {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(day.string(from: start)) · \(time.string(from: start))–\(time.string(from: end))"
        }
        return "\(day.string(from: start)), \(time.string(from: start)) – \(day.string(from: end)), \(time.string(from: end))"
    }

    /// Confirm-screen titles: "Add this event?" (single) / "Add these events?" (multi).
    public static func title(draftCount: Int) -> String {
        draftCount > 1 ? "Add these events?" : "Add this event?"
    }
}
