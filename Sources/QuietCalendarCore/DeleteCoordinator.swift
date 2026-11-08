import Foundation

/// Provider sink for the delete flow. Implementations (EventKit, Google)
/// own the actual transport; the coordinator owns every decision.
///
/// Safety contract implemented by the coordinator on top of this sink:
/// - No mutation ever happens on recognition, matching, selection,
///   preview or cancellation — only on an explicit `confirmDelete()` from
///   the `.confirmOne` state (the user's final "Delete event" click).
/// - The reviewed target is an immutable `DeleteTarget` snapshot; before
///   deleting, the live event is re-fetched and compared against it.
///   Stale/changed targets are rejected without mutation.
/// - Recurring events are never deleted (excluded at match time with an
///   honest reason).
/// - An uncertain remote outcome is never blind-retried: the coordinator
///   re-probes once and reports either verified success or an honest
///   "couldn't confirm" state.
@MainActor
public protocol EventDeleteSink: AnyObject {
    /// Fetch candidates in the query's bounded window on the query's calendar.
    /// Throws on transport/permission problems (never a silent empty list).
    func fetchCandidates(for query: EventLookupQuery) async throws -> [EventCandidate]
    /// Re-fetch one event by its stable provider IDs. Nil = no longer found.
    func refetch(provider: DeleteProvider, calendarID: String, eventID: String) async throws -> EventCandidate?
    /// Delete one event. A definite failure throws any error; an
    /// UNKNOWN-outcome failure (e.g. lost network after send) throws
    /// `DeleteUncertainError` so the coordinator can reconcile.
    func delete(candidate: EventCandidate) async throws
}

/// Thrown by sinks when a delete request was sent but the outcome is
/// unknown (e.g. network dropped after the request). Never retried
/// blindly — the coordinator reconciles via `refetch`.
public struct DeleteUncertainError: Error, Sendable, LocalizedError {
    public var message: String
    public init(message: String) {
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// Read-only error for capability gates (read access missing, read-only
/// calendar, permission loss). Carries a user-facing message.
public struct DeleteUnavailableError: Error, Sendable, LocalizedError {
    public var message: String
    public init(message: String) {
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// The complete delete-flow state, mirrored into the UI.
public enum DeleteFlowState: Sendable, Equatable {
    case idle
    case resolving
    /// Zero exact matches (red caption per design 24:124).
    case noMatch(String)
    /// More than one exact match — explicit chooser, no automatic choice.
    case choose([EventCandidate], selectedID: String?)
    /// Exactly one match (or a chosen candidate) awaiting the final
    /// explicit "Delete event" click.
    case confirmOne(DeleteTarget)
    /// The delete is in flight; repeat clicks and cancel are ignored.
    case deleting(DeleteTarget)
    /// Verified success only — the provider no longer reports the event.
    case deleted(title: String, detail: String)
    /// Definite failure; nothing uncertain claimed.
    case failed(String)
    /// Unknown remote outcome; reconciled as far as possible, never
    /// auto-retried.
    case uncertain(String)
    /// Capability gate (recurring-only matches, read access missing…).
    case unavailable(String)
}

/// Orchestrates: lookup → 0/1/many → explicit chooser → explicit confirm →
/// revalidate → single delete → verified reconciliation.
///
/// The coordinator is idempotent per state: `confirmDelete()` is ignored
/// unless the state is `.confirmOne` (so a double click during a run does
/// nothing), `cancel()` is ignored while `.deleting` (a cancel can never
/// race into an unexpected deletion), and every async result is discarded
/// when a newer flow generation started.
@MainActor
public final class DeleteCoordinator {
    private(set) public var state: DeleteFlowState = .idle
    private var generation = 0

    public init() {}

    public func reset() {
        generation += 1
        state = .idle
    }

    /// Start a new flow from a parsed query. Mutates nothing on the
    /// provider — fetch only.
    public func begin(
        query: DeleteQuery,
        calendarID: String,
        calendarTitle: String = "",
        calendar: Calendar,
        now: Date,
        sink: EventDeleteSink
    ) async -> DeleteFlowState {
        generation += 1
        let token = generation
        state = .resolving

        guard let window = DeleteMatchPolicy.window(
            dateComponents: query.dateComponents,
            calendar: calendar,
            now: now
        ) else {
            state = .noMatch(
                "I couldn’t turn that into a specific day. Say a day like “tomorrow” or “Friday”, then try again."
            )
            return state
        }

        let lookup = EventLookupQuery(
            title: query.title,
            calendarID: calendarID,
            calendarTitle: calendarTitle,
            windowStart: window.start,
            windowEnd: window.end,
            timeComponents: query.timeComponents
        )

        let candidates: [EventCandidate]
        do {
            candidates = try await sink.fetchCandidates(for: lookup)
        } catch let unavailable as DeleteUnavailableError {
            return finish(token, .unavailable(unavailable.message))
        } catch {
            return finish(token, .failed(sanitized(error)))
        }
        guard generation == token else { return state }

        // Exact title + explicit-time matches only. Never fuzzy.
        let recurringMatches = candidates.filter {
            DeleteMatchPolicy.titleMatches(query: query.title, candidate: $0.title) && $0.isRecurring
        }
        let matches = candidates
            .filter {
                DeleteMatchPolicy.titleMatches(query: query.title, candidate: $0.title)
                    && !$0.isRecurring
                    && DeleteMatchPolicy.timeMatches(
                        expected: query.timeComponents,
                        candidateStart: $0.start,
                        calendar: calendar
                    )
            }
            .sorted { $0.start < $1.start }

        switch matches.count {
        case 0:
            if let recurring = recurringMatches.first {
                return finish(token, .unavailable(DeleteFlowCopy.recurringUnavailable(title: recurring.title)))
            }
            return finish(token, .noMatch(DeleteFlowCopy.noMatch))
        case 1:
            return finish(token, .confirmOne(DeleteTarget(candidate: matches[0])))
        default:
            return finish(token, .choose(matches, selectedID: nil))
        }
    }

    /// Chooser selection (design 24:111). No automatic choice is ever made.
    @discardableResult
    public func select(candidateID: String) -> DeleteFlowState {
        guard case .choose(let candidates, _) = state else { return state }
        guard candidates.contains(where: { $0.id == candidateID }) else { return state }
        state = .choose(candidates, selectedID: candidateID)
        return state
    }

    /// Proceed from the chooser to the confirmation panel with the
    /// explicitly selected candidate.
    @discardableResult
    public func confirmSelection() -> DeleteFlowState {
        guard case .choose(let candidates, let selectedID) = state,
              let selected = candidates.first(where: { $0.id == selectedID }) else {
            return state
        }
        state = .confirmOne(DeleteTarget(candidate: selected))
        return state
    }

    /// Cancel from any pre-delete state. Ignored while deleting — a cancel
    /// can never race into an unexpected deletion. Never mutates.
    @discardableResult
    public func cancel() -> DeleteFlowState {
        switch state {
        case .deleting:
            return state
        case .idle:
            return state
        default:
            generation += 1
            state = .idle
            return state
        }
    }

    /// The FINAL explicit user action ("Delete event" click). Only runs
    /// from `.confirmOne`; revalidates the immutable target against live
    /// provider state, performs one delete, then verifies by re-fetch.
    public func confirmDelete(sink: EventDeleteSink, calendar: Calendar) async -> DeleteFlowState {
        guard case .confirmOne(let target) = state else {
            return state // idempotent: repeat clicks while running do nothing
        }
        generation += 1
        let token = generation
        state = .deleting(target)

        // 1. Revalidate: the live event must still match the reviewed
        //    snapshot exactly. Stale/changed/vanished → reject, no mutation.
        let fresh: EventCandidate
        do {
            guard let fetched = try await sink.refetch(
                provider: target.provider,
                calendarID: target.calendarID,
                eventID: target.eventID
            ) else {
                return finish(token, .failed(DeleteFlowCopy.targetVanished))
            }
            guard target.matches(fetched) else {
                return finish(token, .failed(DeleteFlowCopy.staleTarget))
            }
            guard !fetched.isRecurring else {
                return finish(token, .unavailable(DeleteFlowCopy.recurringUnavailable(title: fetched.title)))
            }
            fresh = fetched
        } catch let unavailable as DeleteUnavailableError {
            return finish(token, .unavailable(unavailable.message))
        } catch {
            return finish(token, .failed(sanitized(error)))
        }
        guard generation == token else { return state }

        // 2. Single delete attempt. No bulk, no series, no retry loop.
        do {
            try await sink.delete(candidate: fresh)
        } catch let uncertain as DeleteUncertainError {
            // Unknown outcome: reconcile by ONE re-probe; never blind-retry.
            // A FAILED re-probe proves nothing — it must stay uncertain,
            // never a claimed success.
            let reprobe: EventCandidate?
            do {
                reprobe = try await sink.refetch(
                    provider: target.provider,
                    calendarID: target.calendarID,
                    eventID: target.eventID
                )
            } catch {
                return finish(token, .uncertain(DeleteFlowCopy.deleteUncertain))
            }
            guard generation == token else { return state }
            if reprobe == nil {
                return finish(token, .deleted(title: target.title, detail: relativeDetail(target, calendar: calendar)))
            }
            return finish(token, .uncertain(DeleteFlowCopy.deleteUncertain + " (" + sanitized(uncertain) + ")"))
        } catch {
            return finish(token, .failed(sanitized(error)))
        }
        guard generation == token else { return state }

        // 3. Verified reconciliation before claiming success.
        let verify: EventCandidate?
        do {
            verify = try await sink.refetch(
                provider: target.provider,
                calendarID: target.calendarID,
                eventID: target.eventID
            )
        } catch {
            // Delete reported success but verification could not run —
            // honest uncertain state, never a claimed success.
            return finish(token, .uncertain(DeleteFlowCopy.deleteUncertain))
        }
        guard generation == token else { return state }
        if verify == nil {
            return finish(token, .deleted(title: target.title, detail: relativeDetail(target, calendar: calendar)))
        }
        return finish(token, .failed(DeleteFlowCopy.stillPresentAfterDelete))
    }

    // MARK: - Plumbing

    private func finish(_ token: Int, _ newState: DeleteFlowState) -> DeleteFlowState {
        guard generation == token else { return state }
        state = newState
        return state
    }

    /// One-line "when" for the success row, e.g. "tomorrow at 2:00 PM".
    private func relativeDetail(_ target: DeleteTarget, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: target.start)
    }

    private func sanitized(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "The delete could not be completed."
    }
}
