import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.13 voice-delete: Google REST surface (events.get / events.delete),
/// recurring-instance parsing, and the no-scope-change pin.
/// Mocked transport only — no real Google calls, no tokens.
struct DeleteGoogleClientTests {

    // MARK: - Mocked transport (same pattern as GoogleCalendarIntegrationTests)

    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
    }

    private final class GoogleMockURLProtocol: URLProtocol {
        struct Call: Sendable {
            var url: String
            var method: String
            var authorization: String?
        }
        static let handlers = LockedBox<[String: @Sendable (Call) -> (Int, Data)]>([:])
        static let calls = LockedBox<[Call]>([])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let call = Call(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod ?? "GET",
                authorization: request.value(forHTTPHeaderField: "Authorization"))
            var current = Self.calls.get()
            current.append(call)
            Self.calls.set(current)
            var result: (Int, Data)? = nil
            for (key, handler) in Self.handlers.get() where call.url.contains(key) {
                result = handler(call)
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

        static func setHandler(urlContains key: String, _ handler: @escaping @Sendable (Call) -> (Int, Data)) {
            var map = handlers.get()
            map[key] = handler
            handlers.set(map)
        }
    }

    private func makeClient() -> GoogleCalendarClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleMockURLProtocol.self]
        return GoogleCalendarClient(session: URLSession(configuration: configuration))
    }

    // MARK: - events.delete
    // NOTE: tests in this file run in parallel and share the mock's static
    // handler/call tables — every test claims UNIQUE endpoint keys and
    // inspects only its own calls (same contract as
    // GoogleCalendarIntegrationTests). No reset() calls.

    @Test func deleteEventSendsDELETEWithBearerAndAccepts2xx() async throws {
        GoogleMockURLProtocol.setHandler(urlContains: "/events/del-204") { _ in
            (204, Data())
        }
        let client = makeClient()
        try await client.deleteEvent(calendarID: "cal-1", eventID: "del-204", accessToken: "tok")
        let calls = GoogleMockURLProtocol.calls.get().filter { $0.url.contains("/events/del-204") }
        #expect(calls.count == 1)
        #expect(calls[0].method == "DELETE")
        #expect(calls[0].authorization == "Bearer tok")
        #expect(calls[0].url.contains("/calendars/cal-1/events/del-204"))
    }

    @Test func deleteEvent404IsADefiniteError() async throws {
        GoogleMockURLProtocol.setHandler(urlContains: "/events/del-404") { _ in
            (404, Data())
        }
        let client = makeClient()
        do {
            try await client.deleteEvent(calendarID: "cal-1", eventID: "del-404", accessToken: "tok")
            Issue.record("expected 404 to throw")
        } catch let error as GoogleAPIError {
            guard case .http(let status, _, _) = error, status == 404 else {
                Issue.record("expected http(404), got \(error)")
                return
            }
        } catch {
            Issue.record("expected GoogleAPIError, got \(error)")
        }
    }

    // MARK: - events.get (revalidation)

    @Test func getEventParsesSingleResourceAndNilOn404() async throws {
        GoogleMockURLProtocol.setHandler(urlContains: "/events/get-ok") { _ in
            (200, Data(#"{"id":"get-ok","summary":"Dentist","start":{"dateTime":"2026-11-14T14:00:00-07:00"},"end":{"dateTime":"2026-11-14T15:00:00-07:00"}}"#.utf8))
        }
        GoogleMockURLProtocol.setHandler(urlContains: "/events/get-missing") { _ in
            (404, Data())
        }
        let client = makeClient()
        let event = try await client.getEvent(calendarID: "cal-1", eventID: "get-ok", accessToken: "tok")
        #expect(event?.id == "get-ok")
        #expect(event?.title == "Dentist")
        #expect(event?.start != nil)
        #expect(event?.end != nil)
        #expect(event?.recurringEventId == nil)

        let missing = try await client.getEvent(calendarID: "cal-1", eventID: "get-missing", accessToken: "tok")
        #expect(missing == nil)
    }

    @Test func getEventFlagsRecurringInstances() async throws {
        GoogleMockURLProtocol.setHandler(urlContains: "/events/get-inst") { _ in
            (200, Data(#"{"id":"get-inst","recurringEventId":"orig-1","summary":"Standup","start":{"dateTime":"2026-11-14T09:00:00-07:00"}}"#.utf8))
        }
        let client = makeClient()
        let event = try await client.getEvent(calendarID: "cal-1", eventID: "get-inst", accessToken: "tok")
        #expect(event?.recurringEventId == "orig-1")
    }

    @Test func pageParserFlagsRecurringInstancesAndEnd() throws {
        let page = Data(#"{"items":[{"id":"i1","summary":"A","recurringEventId":"r1","start":{"dateTime":"2026-11-14T09:00:00-07:00"},"end":{"dateTime":"2026-11-14T09:30:00-07:00"}},{"id":"i2","summary":"B","start":{"dateTime":"2026-11-14T10:00:00-07:00"},"end":{"dateTime":"2026-11-14T11:00:00-07:00"}}]}"#.utf8)
        let (items, _) = try GoogleEventsParser.parsePage(page)
        #expect(items.count == 2)
        #expect(items[0].recurringEventId == "r1")
        #expect(items[1].recurringEventId == nil)
        #expect(items[0].end != nil)
    }

    // MARK: - No silent OAuth scope change (delete uses the Add scope)

    @Test func deleteRequiresNoScopeChange() {
        // The already-granted `calendar.events` scope covers events.list,
        // events.get and events.delete. Pin the literal + the requested
        // set so any silent scope broadening fails this test.
        #expect(OAuthAuthorizationURLBuilder.calendarEventsScope == "https://www.googleapis.com/auth/calendar.events")
        #expect(GoogleAuthorizationScopes.requested.count == 3)
        #expect(GoogleAuthorizationScopes.requested.contains(OAuthAuthorizationURLBuilder.calendarEventsScope))
        #expect(GoogleAuthorizationScopes.requested.contains(OAuthAuthorizationURLBuilder.calendarReadonlyScope))
        #expect(GoogleAuthorizationScopes.requested.contains(OAuthAuthorizationURLBuilder.openIDEmailScope))
    }
}
