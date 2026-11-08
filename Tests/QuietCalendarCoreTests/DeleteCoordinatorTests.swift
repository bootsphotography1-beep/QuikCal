import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 voice-delete: coordinator state machine over a mock sink.
/// No GUI, no network, no real provider access — every mutation is
/// asserted to be confirm-gated.
@MainActor
struct DeleteCoordinatorTests {

    // MARK: - Mock sink (in-memory provider)

    @MainActor
    final class DeleteHold {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { c in continuation = c }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    final class MockDeleteSink: EventDeleteSink {
        var fetchResult: Result<[EventCandidate], Error> = .success([])
        /// Live provider state keyed by event ID (what refetch reports).
        var store: [String: EventCandidate] = [:]
        var refetchError: Error?
        var deleteError: Error?
        /// When true, a successful delete removes the event from `store`
        /// (the normal provider behavior the verification step observes).
        var autoRemoveOnDelete = true
        var deleteCallCount = 0
        var deletedIDs: [String] = []
        var deleteHold: DeleteHold?

        func fetchCandidates(for query: EventLookupQuery) async throws -> [EventCandidate] {
            switch fetchResult {
            case .success(let candidates): return candidates
            case .failure(let error): throw error
            }
        }

        func refetch(provider: DeleteProvider, calendarID: String, eventID: String) async throws -> EventCandidate? {
            if let refetchError { throw refetchError }
            return store[eventID]
        }

        func delete(candidate: EventCandidate) async throws {
            deleteCallCount += 1
            if let deleteHold { await deleteHold.wait() }
            // An uncertain error means the request MAY have been applied
            // remotely — simulate that with autoRemove so the coordinator's
            // re-probe reconciles exactly like a real provider.
            if let deleteError {
                if autoRemoveOnDelete { store[candidate.id] = nil }
                throw deleteError
            }
            deletedIDs.append(candidate.id)
            if autoRemoveOnDelete { store[candidate.id] = nil }
        }
    }

    // MARK: - Fixtures

    static let now = Date(timeIntervalSince1970: 1_762_992_000) // fixed instant

    private func makeCandidate(
        id: String,
        title: String,
        startOffsetSeconds: TimeInterval,
        recurring: Bool = false
    ) -> EventCandidate {
        EventCandidate(
            id: id,
            provider: .eventKit,
            calendarID: "cal-1",
            calendarTitle: "Home",
            title: title,
            start: Self.now.addingTimeInterval(startOffsetSeconds),
            end: Self.now.addingTimeInterval(startOffsetSeconds + 3600),
            isRecurring: recurring
        )
    }

    private func makeQuery(title: String, time: DateComponents? = nil) -> DeleteQuery {
        DeleteQuery(rawPhrase: "delete \(title)", title: title, dateComponents: nil, timeComponents: time)
    }

    private func makeSink(_ candidates: [EventCandidate]) -> MockDeleteSink {
        let sink = MockDeleteSink()
        sink.fetchResult = .success(candidates)
        for candidate in candidates { sink.store[candidate.id] = candidate }
        return sink
    }

    // MARK: - Lookup outcomes (no mutation before confirm)

    @Test func noMatchReportsHonestCaptionAndNeverDeletes() async {
        let sink = makeSink([makeCandidate(id: "a", title: "Gym", startOffsetSeconds: 3600)])
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Dentist appointment"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .noMatch(let message) = state else {
            Issue.record("expected noMatch, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.noMatch)
        #expect(sink.deleteCallCount == 0)
    }

    @Test func singleMatchStopsAtConfirmOneWithoutDeleting() async {
        let candidate = makeCandidate(id: "a", title: "Dentist appointment", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Dentist appointment"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .confirmOne(let target) = state else {
            Issue.record("expected confirmOne, got \(state)")
            return
        }
        #expect(target.eventID == "a")
        #expect(target.title == "Dentist appointment")
        // THE core safety gate: matching alone never mutates.
        #expect(sink.deleteCallCount == 0)
    }

    @Test func ambiguousMatchRequiresExplicitChoiceThenConfirmation() async {
        let first = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let second = makeCandidate(id: "b", title: "Dentist", startOffsetSeconds: 7 * 86400)
        let sink = makeSink([first, second])
        let coordinator = DeleteCoordinator()
        var state = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .choose(let candidates, let selected) = state else {
            Issue.record("expected choose, got \(state)")
            return
        }
        #expect(candidates.count == 2)
        #expect(selected == nil) // no automatic choice
        #expect(sink.deleteCallCount == 0)

        // Selecting still does not delete — it only arms the confirm panel.
        state = coordinator.select(candidateID: "b")
        guard case .choose(_, let newSelected) = state else {
            Issue.record("expected choose after select")
            return
        }
        #expect(newSelected == "b")
        #expect(sink.deleteCallCount == 0)

        state = coordinator.confirmSelection()
        guard case .confirmOne(let target) = state else {
            Issue.record("expected confirmOne after explicit selection")
            return
        }
        #expect(target.eventID == "b")
        #expect(sink.deleteCallCount == 0)

        state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .deleted = state else {
            Issue.record("expected verified deleted, got \(state)")
            return
        }
        #expect(sink.deletedIDs == ["b"])
        #expect(sink.deletedIDs.count == 1)
    }

    // MARK: - Cancellation (never mutates, never races)

    @Test func cancelFromChooserAndConfirmNeverDeletes() async {
        for stage in 0..<2 {
            let first = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
            let second = makeCandidate(id: "b", title: "Dentist", startOffsetSeconds: 7 * 86400)
            let sink = makeSink([first, second])
            let coordinator = DeleteCoordinator()
            _ = await coordinator.begin(
                query: makeQuery(title: "Dentist"),
                calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
            if stage == 0 {
                _ = coordinator.cancel()
            } else {
                _ = coordinator.select(candidateID: "a")
                _ = coordinator.confirmSelection()
                _ = coordinator.cancel()
            }
            #expect(coordinator.state == .idle)
            #expect(sink.deleteCallCount == 0)
        }
    }

    /// Yields until the coordinator reports the given state (bounded).
    private func yieldUntil(
        _ coordinator: DeleteCoordinator,
        is state: @Sendable (DeleteFlowState) -> Bool,
        limit: Int = 200
    ) async {
        for _ in 0..<limit {
            await Task.yield()
            if state(coordinator.state) { return }
        }
    }

    @Test func cancelDuringInFlightDeleteIsIgnoredAndDeleteStillVerified() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        let hold = DeleteHold()
        sink.deleteHold = hold
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)

        let inFlight = Task { await coordinator.confirmDelete(sink: sink, calendar: .current) }
        await yieldUntil(coordinator, is: { if case .deleting = $0 { return true }; return false })
        #expect(sink.deleteCallCount == 1) // the delete is really in flight
        // A cancel while deleting is ignored — it can never race into an
        // unexpected deletion, and it can never cancel the in-flight one.
        let duringCancel = coordinator.cancel()
        #expect({ if case .deleting = duringCancel { return true }; return false }())
        hold.release()
        let final = await inFlight.value
        guard case .deleted = final else {
            Issue.record("expected verified deleted despite racing cancel, got \(final)")
            return
        }
        #expect(sink.deleteCallCount == 1)
    }

    @Test func doubleConfirmWhileRunningDeletesExactlyOnce() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        let hold = DeleteHold()
        sink.deleteHold = hold
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)

        let first = Task { await coordinator.confirmDelete(sink: sink, calendar: .current) }
        await yieldUntil(coordinator, is: { if case .deleting = $0 { return true }; return false })
        #expect(sink.deleteCallCount == 1)
        // Second click while the first is running: state is .deleting, so
        // the guard rejects it — no second delete request.
        let second = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .deleting = second else {
            Issue.record("expected second confirm to be ignored while deleting")
            return
        }
        hold.release()
        _ = await first.value
        #expect(sink.deleteCallCount == 1)
    }

    // MARK: - Revalidation (stale/changed targets are rejected)

    @Test func staleChangedTargetIsRejectedWithoutDeletion() async {
        let original = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([original])
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        // The event is retitled between review and confirm.
        var changed = original
        changed.title = "Dentist — rescheduled"
        sink.store["a"] = changed
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .failed(let message) = state else {
            Issue.record("expected failed for stale target, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.staleTarget)
        #expect(sink.deleteCallCount == 0)
    }

    @Test func vanishedTargetIsRejectedWithoutDeletion() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        sink.store["a"] = nil // deleted elsewhere
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .failed(let message) = state else {
            Issue.record("expected failed for vanished target, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.targetVanished)
        #expect(sink.deleteCallCount == 0)
    }

    // MARK: - Recurring targets are never deletable

    @Test func recurringCandidatesAreExcludedFromMatches() async {
        let recurring = makeCandidate(id: "a", title: "Standup", startOffsetSeconds: 3600, recurring: true)
        let single = makeCandidate(id: "b", title: "Standup", startOffsetSeconds: 86400)
        let sink = makeSink([recurring, single])
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Standup"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .confirmOne(let target) = state else {
            Issue.record("expected confirmOne for the non-recurring match only, got \(state)")
            return
        }
        #expect(target.eventID == "b")
    }

    @Test func recurringOnlyMatchIsHonestlyUnavailable() async {
        let recurring = makeCandidate(id: "a", title: "Standup", startOffsetSeconds: 3600, recurring: true)
        let sink = makeSink([recurring])
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Standup"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .unavailable(let message) = state else {
            Issue.record("expected unavailable for recurring-only match, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.recurringUnavailable(title: "Standup"))
        #expect(sink.deleteCallCount == 0)
    }

    // MARK: - Success, verification, uncertain outcomes, provider errors

    @Test func verifiedSuccessRequiresProviderToStopReportingTheEvent() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .deleted(let title, _) = state else {
            Issue.record("expected verified deleted, got \(state)")
            return
        }
        #expect(title == "Dentist")
        #expect(sink.deleteCallCount == 1)
    }

    @Test func stillPresentAfterDeleteIsAnHonestFailure() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        sink.autoRemoveOnDelete = false // provider keeps reporting it
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .failed(let message) = state else {
            Issue.record("expected honest failure when still present, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.stillPresentAfterDelete)
    }

    @Test func uncertainOutcomeReconcilesToVerifiedDeletedWhenGone() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        sink.deleteError = DeleteUncertainError(message: "connection lost")
        // Delete "succeeded" remotely despite the lost response: the
        // re-probe finds nothing.
        sink.autoRemoveOnDelete = true
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .deleted = state else {
            Issue.record("expected verified deleted after uncertain outcome, got \(state)")
            return
        }
        // No blind retry: exactly one delete request was ever sent.
        #expect(sink.deleteCallCount == 1)
    }

    @Test func uncertainOutcomeStaysUncertainWhenStillPresent_NoRetry() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        sink.deleteError = DeleteUncertainError(message: "connection lost")
        sink.autoRemoveOnDelete = false // re-probe still finds it
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .uncertain(let message) = state else {
            Issue.record("expected uncertain, got \(state)")
            return
        }
        #expect(message.contains(DeleteFlowCopy.deleteUncertain))
        #expect(sink.deleteCallCount == 1) // never a blind retry
    }

    @Test func definiteProviderErrorIsAnHonestFailure() async {
        let candidate = makeCandidate(id: "a", title: "Dentist", startOffsetSeconds: 86400)
        let sink = makeSink([candidate])
        sink.deleteError = DeleteUnavailableError(message: "That calendar is read-only — QuikCal can’t delete from it.")
        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        let state = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .failed(let message) = state else {
            Issue.record("expected failed for provider error, got \(state)")
            return
        }
        #expect(message.contains("read-only"))
    }

    @Test func fetchCapabilityGateIsUnavailableNotFailure() async {
        let sink = MockDeleteSink()
        sink.fetchResult = .failure(
            DeleteUnavailableError(message: DeleteFlowCopy.eventKitFullAccessNeeded))
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .unavailable(let message) = state else {
            Issue.record("expected unavailable for capability gate, got \(state)")
            return
        }
        #expect(message == DeleteFlowCopy.eventKitFullAccessNeeded)
    }

    @Test func fetchTransportErrorIsAFailureNeverASilentEmptyList() async {
        let sink = MockDeleteSink()
        struct Boom: Error {}
        sink.fetchResult = .failure(Boom())
        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: makeQuery(title: "Dentist"),
            calendarID: "cal-1", calendar: .current, now: Self.now, sink: sink)
        guard case .failed = state else {
            Issue.record("expected failed for transport error, got \(state)")
            return
        }
    }

    // MARK: - Explicit-time filtering

    @Test func statedTimeFiltersCandidatesToThatHourMinute() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 14
        let dayStart = calendar.date(from: comps)!

        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)!
        }
        // Build explicit-date candidates.
        let right = EventCandidate(
            id: "a", provider: .eventKit, calendarID: "cal-1", calendarTitle: "Home",
            title: "Dentist", start: at(14, 0), end: at(15, 0), isRecurring: false)
        let wrong = EventCandidate(
            id: "b", provider: .eventKit, calendarID: "cal-1", calendarTitle: "Home",
            title: "Dentist", start: at(14, 30), end: at(15, 30), isRecurring: false)
        let sink = makeSink([right, wrong])
        let coordinator = DeleteCoordinator()
        var stated = DateComponents(); stated.hour = 14; stated.minute = 0
        let state = await coordinator.begin(
            query: makeQuery(title: "Dentist", time: stated),
            calendarID: "cal-1", calendar: calendar, now: Self.now, sink: sink)
        guard case .confirmOne(let target) = state else {
            Issue.record("expected the 2:00 PM match only, got \(state)")
            return
        }
        #expect(target.eventID == "a")
    }
}
