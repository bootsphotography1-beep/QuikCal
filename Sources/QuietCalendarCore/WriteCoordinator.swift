import Foundation

/// Batch calendar writes for the confirmation set — honest EventKit semantics.
///
/// The coordinator stages **all** targeted drafts first (`commit: false`).
/// `commit()` is called **only if every stage passed**. If any stage fails,
/// the owned staged batch is discarded (`reset()` on the write store only),
/// `commit()` is never called, nothing is counted as saved, and every draft
/// is preserved for retry. Already-saved / blocked / exact-match drafts are
/// not staged and never rewritten.
///
/// Commit failure: EventKit `commit()` failure is best-effort — the API does
/// not give a universal atomic-rollback guarantee. On commit failure the
/// coordinator discards staged work and marks candidates
/// `.commitUncertain` (not "saved", not "failed-to-stage"): the next retry
/// re-probes exact matches before staging, so a partially persisted event is
/// reconciled as already-saved instead of duplicated. Copy must describe
/// this as best-effort per EventKit, never as universal atomicity.
public enum DraftWriteOutcome: Sendable, Equatable {
    case created(id: String)
    case exactMatchNeedsConfirmation
    case alreadySaved(id: String)
    case failed(String)
    /// Commit threw after all stages passed. Persistence is uncertain —
    /// reconcile via exact-match probe before retry; never duplicate.
    case commitUncertain(String)
}

@MainActor
public protocol CalendarWriteSink: AnyObject {
    /// Exact-match probe used for the duplicate warning and post-commit reconciliation.
    func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) -> Bool
    /// Stages one event without committing (EventKit `commit: false`).
    /// `reminderLeadMinutes` (nil = none) attaches an alarm BEFORE the event
    /// start — it never shifts start/end. `notes` (nil/empty = none) is the
    /// reviewed user description persisted to `EKEvent.notes`.
    func stageEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) throws -> String
    /// Persists the staged batch (EventKit `commit()`).
    func commitStaged() throws
    /// Discards staged work (EventKit `reset()` on the write store only).
    func discardStaged()
}

public struct WriteCoordinator: Sendable {
    public init() {}

    @MainActor
    public func write(
        drafts: [ConfirmationDraft],
        calendarID: String,
        calendarSummary: String? = nil,
        sink: CalendarWriteSink
    ) -> (outcomes: [UUID: DraftWriteOutcome], receipts: [SavedEventReceipt], anySaved: Bool, anyFailed: Bool) {
        var outcomes: [UUID: DraftWriteOutcome] = [:]
        var receipts: [SavedEventReceipt] = []
        var stagedIDs: [UUID: String] = [:]
        var candidates: [ConfirmationDraft] = []

        for draft in drafts {
            if let saved = draft.savedEventID {
                outcomes[draft.id] = .alreadySaved(id: saved)
                continue
            }
            if !draft.canAdd {
                outcomes[draft.id] = .failed("Not ready to add yet.")
                continue
            }
            if !draft.duplicateAddArmed,
               sink.hasExactMatch(title: draft.title, start: draft.start, end: draft.end,
                                  location: draft.location, calendarID: calendarID) {
                outcomes[draft.id] = .exactMatchNeedsConfirmation
                continue
            }
            candidates.append(draft)
        }

        guard !candidates.isEmpty else {
            return (outcomes, receipts, false, outcomes.values.contains { if case .failed = $0 { return true }; return false })
        }

        // Stage ALL candidates first. Any stage failure aborts the whole
        // batch: discard staged work, never call commit, save nothing.
        var stageFailure: (draftID: UUID, message: String)? = nil
        for draft in candidates {
            do {
                let id = try sink.stageEvent(title: draft.title, start: draft.start, end: draft.end,
                                             location: draft.location, notes: draft.notes,
                                             reminderLeadMinutes: draft.reminderLeadMinutes,
                                             calendarID: calendarID)
                stagedIDs[draft.id] = id
            } catch {
                stageFailure = (draft.id, error.localizedDescription)
                break
            }
        }
        if let failure = stageFailure {
            sink.discardStaged()
            for draft in candidates {
                if draft.id == failure.draftID {
                    outcomes[draft.id] = .failed(failure.message)
                } else {
                    outcomes[draft.id] = .failed("Batch discarded — nothing was saved. Fix the failed event and try again.")
                }
            }
            return (outcomes, receipts, false, true)
        }

        do {
            try sink.commitStaged()
            let savedAt = Date()
            for draft in candidates {
                guard let id = stagedIDs[draft.id] else { continue }
                outcomes[draft.id] = .created(id: id)
                // Receipt ONLY for the confirmed persisted write.
                receipts.append(SavedEventReceipt(
                    draftID: draft.id,
                    provider: .eventKit,
                    eventID: id,
                    calendarID: calendarID,
                    calendarSummary: calendarSummary,
                    title: draft.title,
                    start: draft.start,
                    end: draft.end,
                    location: draft.location,
                    notes: draft.notes,
                    reminderLeadMinutes: draft.reminderLeadMinutes,
                    savedAt: savedAt))
            }
            return (outcomes, receipts, true, outcomes.values.contains { if case .failed = $0 { return true }; return false })
        } catch {
            // Best-effort discard, then reconcile: anything that now exact-
            // matches was persisted despite the throw — report it as
            // alreadySaved so retry never duplicates it. The rest are
            // commitUncertain (not claimed saved, not a stage failure).
            sink.discardStaged()
            let message = error.localizedDescription
            for draft in candidates {
                if sink.hasExactMatch(title: draft.title, start: draft.start, end: draft.end,
                                      location: draft.location, calendarID: calendarID),
                   let id = stagedIDs[draft.id] {
                    outcomes[draft.id] = .alreadySaved(id: id)
                } else {
                    outcomes[draft.id] = .commitUncertain(message)
                }
            }
            let anyFailed = outcomes.values.contains { if case .commitUncertain = $0 { return true }; return false }
            // Nothing is claimed newly created here, so no receipts: events
            // that reconciled as alreadySaved were persisted by an earlier
            // write, whose receipt belongs to that write.
            return (outcomes, receipts, false, anyFailed)
        }
    }
}

/// In-memory sink for tests and the packaged synthetic acceptance.
@MainActor
public final class MockCalendarSink: CalendarWriteSink {
    public var exactMatches: Set<String> = []
    public var stageFailureFor: Set<String> = []
    public var commitFailure = false
    public var staged: [String: (title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String)] = [:]
    public var committed: [(id: String, title: String)] = []
    public var commitCallCount = 0
    public var discardCallCount = 0
    private var stagedIDs: [UUID: String] = [:]
    private var counter = 0

    private func key(title: String, start: Date, end: Date, location: String?, calendarID: String) -> String {
        [title, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
         location ?? "", calendarID].joined(separator: "|")
    }

    public func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) -> Bool {
        exactMatches.contains(key(title: title, start: start, end: end, location: location, calendarID: calendarID))
    }

    public func stageEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) throws -> String {
        if stageFailureFor.contains(title) { throw MockSinkError.stage(title) }
        counter += 1
        let id = "mock-\(counter)"
        staged[key(title: title, start: start, end: end, location: location, calendarID: calendarID)] =
            (title, start, end, location, notes, reminderLeadMinutes, calendarID)
        return id
    }

    public func commitStaged() throws {
        commitCallCount += 1
        if commitFailure { throw MockSinkError.commit }
        committed.append(contentsOf: staged.map { (id: $0.key, title: $0.value.title) })
        staged.removeAll()
    }

    public func discardStaged() {
        discardCallCount += 1
        staged.removeAll()
    }
}

public enum MockSinkError: Error, Equatable, LocalizedError {
    case stage(String)
    case commit
    public var errorDescription: String? {
        switch self {
        case .stage(let title): return "Could not stage “\(title)”."
        case .commit: return "Could not save to the calendar."
        }
    }
}
