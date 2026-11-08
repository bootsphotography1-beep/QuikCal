import Foundation

/// Batch writes to Google Calendar — honest per-event semantics.
///
/// Unlike EventKit staging (`commit: false`), Google `events.insert` persists
/// immediately: there is no two-phase stage/commit. The coordinator therefore
/// writes each candidate **sequentially** and reports per-draft outcomes:
///
/// - Already-saved / blocked drafts are never rewritten.
/// - Exact-match probe (same title + start ±1s + location) blocks a draft
///   unless the duplicate add was explicitly armed — no silent duplicates.
/// - An insert failure marks **that draft** `.failed` and the remaining
///   drafts are still attempted. Copy must NEVER claim "nothing was saved"
///   for Google — earlier successes are real and reported as `.created`.
/// - A network failure whose outcome is unknown (request sent, response
///   lost) is reported `.commitUncertain`: the draft is kept and a retry
///   re-probes exact matches first, so an actually-persisted event is
///   recognised instead of duplicated.
public enum GoogleWriteCoordinator: Sendable {
    @MainActor
    public protocol Sink: AnyObject {
        /// Exact-match probe against the target Google calendar.
        /// Throwing means the duplicate check could not run — the draft is
        /// failed, never written (fail-closed: no write without the check).
        func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) async throws -> Bool
        /// Inserts one event. `notes` (nil/empty = none) persists as the
        /// Google event `description` — the reviewed user detail.
        /// `reminderLeadMinutes` (nil = none) becomes an explicit popup
        /// reminder override with `useDefault: false`; nil leaves the
        /// calendar's default reminders untouched. Throws on failure; on
        /// an *unknown-outcome* network error the sink should throw
        /// `GoogleAPIError.network(_:)`.
        func insertEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) async throws -> GoogleInsertedEvent
    }

    @MainActor
    public static func write(
        drafts: [ConfirmationDraft],
        calendarID: String,
        calendarSummary: String? = nil,
        sink: Sink
    ) async -> (outcomes: [UUID: DraftWriteOutcome], receipts: [SavedEventReceipt], anySaved: Bool, anyFailed: Bool) {
        var outcomes: [UUID: DraftWriteOutcome] = [:]
        var receipts: [SavedEventReceipt] = []

        for draft in drafts {
            if let saved = draft.savedEventID {
                outcomes[draft.id] = .alreadySaved(id: saved)
            } else if !draft.canAdd {
                outcomes[draft.id] = .failed("Not ready to add yet.")
            }
        }

        for draft in drafts where outcomes[draft.id] == nil {
            if !draft.duplicateAddArmed {
                do {
                    let exists = try await sink.hasExactMatch(
                        title: draft.title, start: draft.start, end: draft.end,
                        location: draft.location, calendarID: calendarID)
                    if exists {
                        outcomes[draft.id] = .exactMatchNeedsConfirmation
                        continue
                    }
                } catch {
                    // Fail-closed: the duplicate check could not run, so the
                    // event is never written. This is a definite failure —
                    // nothing was sent — not a commitUncertain.
                    outcomes[draft.id] = .failed(error.localizedDescription)
                    continue
                }
            }
            do {
                let inserted = try await sink.insertEvent(
                    title: draft.title, start: draft.start, end: draft.end,
                    location: draft.location, notes: draft.notes,
                    reminderLeadMinutes: draft.reminderLeadMinutes,
                    calendarID: calendarID)
                outcomes[draft.id] = .created(id: inserted.id)
                // Receipt ONLY for the confirmed persisted insert.
                receipts.append(SavedEventReceipt(
                    draftID: draft.id,
                    provider: .google,
                    eventID: inserted.id,
                    eventURL: inserted.htmlLink,
                    calendarID: calendarID,
                    calendarSummary: calendarSummary,
                    title: draft.title,
                    start: draft.start,
                    end: draft.end,
                    location: draft.location,
                    notes: draft.notes,
                    reminderLeadMinutes: draft.reminderLeadMinutes,
                    savedAt: Date()))
            } catch let error as GoogleAPIError where isUnknownOutcome(error) {
                // Unknown outcome — the insert may or may not have persisted.
                outcomes[draft.id] = .commitUncertain(error.localizedDescription)
            } catch {
                outcomes[draft.id] = .failed(error.localizedDescription)
            }
        }

        let anySaved = outcomes.values.contains {
            if case .created = $0 { return true }
            if case .alreadySaved = $0 { return true }
            return false
        }
        let anyFailed = outcomes.values.contains {
            if case .failed = $0 { return true }
            if case .commitUncertain = $0 { return true }
            return false
        }
        return (outcomes, receipts, anySaved, anyFailed)
    }

    /// A network error after the request was sent leaves the outcome unknown.
    /// Failures where Google definitively rejected the insert (HTTP error
    /// status) are deterministic `.failed`, not uncertain.
    private static func isUnknownOutcome(_ error: GoogleAPIError) -> Bool {
        if case .network = error { return true }
        return false
    }
}
