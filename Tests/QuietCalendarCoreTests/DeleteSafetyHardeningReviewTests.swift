import Testing
import Foundation
@testable import QuietCalendarCore

/// Independent review hardening tests (2026-11-07, Go reviewer).
///
/// These pin the three deletion-safety upgrades added during review:
/// 1. Google series MASTERS are flagged via the `recurrence` field — not
///    only `recurringEventId` instances — so no master can ever be
///    treated as a plain single event.
/// 2. `events.get` etags are parsed and `events.delete` sends `If-Match`
///    (Google documents If-Match for delete), closing the
///    revalidate→delete TOCTOU window: a concurrent edit becomes a
///    definite 412 rejection, never a delete of a changed event.
/// 3. The coordinator surfaces a definite stale/precondition failure
///    honestly (no retry, no success claim).
///
/// Mocked transport only — no network, no tokens, no provider access.
struct DeleteSafetyHardeningReviewTests {

    // MARK: - Mocked transport (captures ALL headers incl. If-Match)

    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
        /// Atomic read-modify-write. Without this, two concurrent
        /// `setHandler` calls can each read the same base map and one
        /// registration is silently lost (review finding 2026-11-07: the
        /// 412 handler vanished under parallel test setup, the request
        /// then hit the mock's default 500 and the test failed as a
        /// flake).
        func update(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
    }

    private struct CapturedRequest: Sendable, Equatable {
        var url: String
        var method: String
        var authorization: String?
        var ifMatch: String?
    }

    private final class HeaderCapturingURLProtocol: URLProtocol {
        static let handlers = LockedBox<[String: @Sendable (CapturedRequest) -> (Int, Data)]>([:])
        static let captured = LockedBox<[CapturedRequest]>([])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let captured = CapturedRequest(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod ?? "GET",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                ifMatch: request.value(forHTTPHeaderField: "If-Match")
            )
            // Atomic append: concurrent tests capturing requests must never
            // lose a record (same lost-update class as setHandler).
            Self.captured.update { $0.append(captured) }
            var result: (Int, Data)? = nil
            for (key, handler) in Self.handlers.get() where captured.url.contains(key) {
                result = handler(captured)
                break
            }
            let status = result?.0 ?? 500
            let data = result?.1 ?? Data("{}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func setHandler(urlContains key: String, _ handler: @escaping @Sendable (CapturedRequest) -> (Int, Data)) {
            // Atomic registration: a plain get+set can lose a concurrent
            // registration (lost update) under parallel test setup.
            handlers.update { $0[key] = handler }
        }
    }

    private func makeClient() -> GoogleCalendarClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderCapturingURLProtocol.self]
        return GoogleCalendarClient(session: URLSession(configuration: configuration))
    }

    private func capturedRequests(containing key: String) -> [CapturedRequest] {
        HeaderCapturingURLProtocol.captured.get().filter { $0.url.contains(key) }
    }

    // MARK: - 1. Series masters via the `recurrence` field

    @Test func getEventFlagsSeriesMastersViaRecurrenceField() async throws {
        // A series MASTER: no recurringEventId, but recurrence rules on
        // the resource itself. Must be flagged as recurring so it is
        // never deletable as a plain event.
        HeaderCapturingURLProtocol.setHandler(urlContains: "/events/rv-master") { _ in
            (200, Data(#"{"id":"rv-master","summary":"Standup","recurrence":["RRULE:FREQ=WEEKLY;BYDAY=MO"],"etag":"\"m1\"","start":{"dateTime":"2026-11-16T09:00:00-07:00"}}"#.utf8))
        }
        let client = makeClient()
        let event = try await client.getEvent(calendarID: "cal-1", eventID: "rv-master", accessToken: "tok")
        #expect(event != nil)
        #expect(event?.recurringEventId == nil)
        #expect(event?.hasRecurrenceRules == true)
    }

    @Test func pageParserFlagsSeriesMastersViaRecurrenceField() throws {
        let page = Data(
            #"{"items":[{"id":"pm1","summary":"Weekly sync","recurrence":["RRULE:FREQ=DAILY"],"start":{"dateTime":"2026-11-16T09:00:00-07:00"}},{"id":"pm2","summary":"One-off","start":{"dateTime":"2026-11-16T10:00:00-07:00"}}]}"#.utf8)
        let (items, _) = try GoogleEventsParser.parsePage(page)
        #expect(items.count == 2)
        #expect(items.first(where: { $0.id == "pm1" })?.hasRecurrenceRules == true)
        #expect(items.first(where: { $0.id == "pm2" })?.hasRecurrenceRules == false)
        #expect(items.first(where: { $0.id == "pm2" })?.recurringEventId == nil)
    }

    @Test func emptyRecurrenceArrayIsNotRecurring() throws {
        let page = Data(
            #"{"items":[{"id":"pe1","summary":"Plain","recurrence":[],"start":{"dateTime":"2026-11-16T09:00:00-07:00"}}]}"#.utf8)
        let (items, _) = try GoogleEventsParser.parsePage(page)
        #expect(items.first?.hasRecurrenceRules == false)
    }

    // MARK: - 2. Etag parse + conditional delete (If-Match)

    @Test func getEventParsesEtag() async throws {
        HeaderCapturingURLProtocol.setHandler(urlContains: "/events/rv-etag") { _ in
            (200, Data(#"{"id":"rv-etag","summary":"Dentist","etag":"\"etag-42\"","start":{"dateTime":"2026-11-14T14:00:00-07:00"}}"#.utf8))
        }
        let client = makeClient()
        let event = try await client.getEvent(calendarID: "cal-1", eventID: "rv-etag", accessToken: "tok")
        #expect(event?.etag == "\"etag-42\"")
    }

    @Test func deleteEventSendsIfMatchHeaderWhenEtagSupplied() async throws {
        HeaderCapturingURLProtocol.setHandler(urlContains: "/events/rv-del-etag") { _ in
            (204, Data())
        }
        let client = makeClient()
        try await client.deleteEvent(
            calendarID: "cal-1", eventID: "rv-del-etag", accessToken: "tok",
            ifMatch: "\"etag-42\"")
        let calls = capturedRequests(containing: "/events/rv-del-etag")
        #expect(calls.count == 1)
        #expect(calls[0].method == "DELETE")
        #expect(calls[0].ifMatch == "\"etag-42\"")
        #expect(calls[0].authorization == "Bearer tok")
    }

    @Test func deleteEventOmitsIfMatchHeaderWithoutEtag() async throws {
        HeaderCapturingURLProtocol.setHandler(urlContains: "/events/rv-del-noetag") { _ in
            (204, Data())
        }
        let client = makeClient()
        try await client.deleteEvent(
            calendarID: "cal-1", eventID: "rv-del-noetag", accessToken: "tok")
        let calls = capturedRequests(containing: "/events/rv-del-noetag")
        #expect(calls.count == 1)
        #expect(calls[0].ifMatch == nil)
    }

    @Test func deleteEvent412PreconditionFailedIsADefiniteHTTPError() async throws {
        // Google returns 412 when If-Match no longer matches — a definite
        // "changed since revalidation" outcome. At the Core client level
        // it must surface as a distinct http error (the app-layer sink
        // maps it to the honest stale-target message); never a network
        // (uncertain) error and never success.
        HeaderCapturingURLProtocol.setHandler(urlContains: "/events/rv-del-412") { _ in
            (412, Data())
        }
        let client = makeClient()
        do {
            try await client.deleteEvent(
                calendarID: "cal-1", eventID: "rv-del-412", accessToken: "tok",
                ifMatch: "\"stale-etag\"")
            Issue.record("expected GoogleAPIError.http(412)")
        } catch let error as GoogleAPIError {
            guard case .http(let status, _, _) = error, status == 412 else {
                Issue.record("expected .http(412), got \(error)")
                return
            }
        }
    }

    // MARK: - 3. Coordinator honesty on a definite stale/precondition failure

    @MainActor
    private final class PreconditionMockSink: EventDeleteSink {
        var store: [String: EventCandidate] = [:]
        var deleteCallCount = 0
        var deleteCandidate: EventCandidate?

        func fetchCandidates(for query: EventLookupQuery) async throws -> [EventCandidate] {
            Array(store.values)
        }

        func refetch(provider: DeleteProvider, calendarID: String, eventID: String) async throws -> EventCandidate? {
            store[eventID]
        }

        func delete(candidate: EventCandidate) async throws {
            deleteCallCount += 1
            deleteCandidate = candidate
            // The provider rejected the delete because the event changed
            // since revalidation (If-Match 412 semantics).
            throw DeleteUnavailableError(message: DeleteFlowCopy.staleTarget)
        }
    }

    @MainActor
    @Test func definiteStalePreconditionFailureIsHonestFailureWithNoRetry() async {
        let now = Date(timeIntervalSince1970: 1_762_992_000)
        let target = EventCandidate(
            id: "e1", provider: .google, calendarID: "cal-1", calendarTitle: "Work",
            title: "Standup", start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(4200), isRecurring: false,
            etag: "\"etag-42\"")
        let sink = PreconditionMockSink()
        sink.store["e1"] = target

        let coordinator = DeleteCoordinator()
        let state = await coordinator.begin(
            query: DeleteQuery(rawPhrase: "delete standup", title: "Standup",
                               dateComponents: nil, timeComponents: nil),
            calendarID: "cal-1", calendarTitle: "Work",
            calendar: .current, now: now, sink: sink)
        guard case .confirmOne = state else {
            Issue.record("expected confirmOne, got \(state)")
            return
        }
        let final = await coordinator.confirmDelete(sink: sink, calendar: .current)
        guard case .failed(let message) = final else {
            Issue.record("expected .failed, got \(final)")
            return
        }
        #expect(message == DeleteFlowCopy.staleTarget)
        #expect(message.contains("nothing was deleted"))
        // Exactly ONE delete attempt — no retry after a definite refusal.
        #expect(sink.deleteCallCount == 1)
    }

    @MainActor
    @Test func refetchedEtagFlowsToTheDeleteCall() async {
        // End-to-end plumbing: the candidate the coordinator hands to
        // delete() must carry the etag from the revalidating refetch, so
        // the sink can make the delete conditional.
        let now = Date(timeIntervalSince1970: 1_762_992_000)
        let target = EventCandidate(
            id: "e2", provider: .google, calendarID: "cal-1", calendarTitle: "Work",
            title: "Retro", start: now.addingTimeInterval(7200),
            end: now.addingTimeInterval(7800), isRecurring: false,
            etag: "\"etag-99\"")
        let sink = PreconditionMockSink()
        // The sink's delete throws a precondition failure; success paths
        // for etag-carrying deletes are covered by the 2xx client tests.
        sink.store["e2"] = target

        let coordinator = DeleteCoordinator()
        _ = await coordinator.begin(
            query: DeleteQuery(rawPhrase: "delete retro", title: "Retro",
                               dateComponents: nil, timeComponents: nil),
            calendarID: "cal-1", calendarTitle: "Work",
            calendar: .current, now: now, sink: sink)
        _ = await coordinator.confirmDelete(sink: sink, calendar: .current)
        #expect(sink.deleteCandidate?.etag == "\"etag-99\"")
        #expect(sink.deleteCandidate?.id == "e2")
    }
}
