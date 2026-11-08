import Testing
import Foundation
@testable import QuietCalendarCore

// MARK: - Mocked network plumbing (no real Google calls in tests)

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
        var body: String
        var authorization: String?
    }

    /// Handlers keyed by URL substring — tests run in parallel, so each test
    /// only claims its own endpoint(s) and inspects only its own calls.
    static let handlers = LockedBox<[String: @Sendable (Call) -> (Int, Data)]>([:])
    static let calls = LockedBox<[Call]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyText = Self.readBody(request)
        let call = Call(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            body: bodyText,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        var current = Self.calls.get()
        current.append(call)
        Self.calls.set(current)
        var result: (Int, Data)? = nil
        for (key, handler) in Self.handlers.get() where call.url.contains(key) {
            result = handler(call)
            break
        }
        let status = result?.0 ?? 500
        let data = result?.1 ?? Data(#"{"error":{"code":500}}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func readBody(_ request: URLRequest) -> String {
        if let body = request.httpBody, let s = String(data: body, encoding: .utf8) { return s }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func setHandler(urlContains key: String, _ handler: @escaping @Sendable (Call) -> (Int, Data)) {
        var map = handlers.get()
        map[key] = handler
        handlers.set(map)
    }

    static func callsMatching(_ substring: String) -> [Call] {
        calls.get().filter { $0.url.contains(substring) }
    }

    static func reset() {
        calls.set([])
        handlers.set([:])
    }
}

private func mockedClient(fixedNow: Date = Date(timeIntervalSince1970: 1_000_000)) -> GoogleCalendarClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GoogleMockURLProtocol.self]
    return GoogleCalendarClient(
        session: URLSession(configuration: config),
        now: { fixedNow }
    )
}

private func json(_ string: String) -> Data { Data(string.utf8) }

// MARK: - Mock coordinator sink

@MainActor
private final class MockGoogleSink: GoogleWriteCoordinator.Sink {
    var exactMatches: Set<String> = []
    var insertResults: [Result<GoogleInsertedEvent, Error>] = []
    var probeError: Error?
    private(set) var probeCount = 0
    private(set) var insertCount = 0
    var failProbeForAllAfterFirst: Bool = false
    var lastReminderLeadMinutes: Int?

    private func key(title: String, start: Date) -> String {
        "\(title)|\(String(start.timeIntervalSince1970))"
    }

    func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) async throws -> Bool {
        probeCount += 1
        if let probeError { throw probeError }
        return exactMatches.contains(key(title: title, start: start))
    }

    func insertEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) async throws -> GoogleInsertedEvent {
        insertCount += 1
        lastReminderLeadMinutes = reminderLeadMinutes
        guard !insertResults.isEmpty else { return GoogleInsertedEvent(id: "evt-\(insertCount)") }
        return try insertResults.removeFirst().get()
    }
}

// MARK: - Tests

/// `.serialized`: these tests share one URLProtocol mock registry; the suite's
/// tests must not reset handlers while a sibling test's request is in flight.
@Suite(.serialized)
struct GoogleCalendarIntegrationTests {
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "quietcalendar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeDraft(title: String = "Standup", start: Date = Date(timeIntervalSince1970: 1_800_000), end: Date? = nil, location: String? = nil) -> ConfirmationDraft {
        ConfirmationDraft(
            title: title, start: start, end: end ?? start.addingTimeInterval(1800),
            location: location, source: .builtInParser,
            provenance: DraftProvenance(
                source: .builtInParser, transcript: "standup",
                referenceNowISO: "2026-11-06T00:00:00Z", timeZoneID: "Australia/Sydney")
        )
    }

    // Token bundle vault

    @Test func tokenBundleVaultRoundTrip() throws {
        let vault = MutableInMemoryGoogleTokenVault()
        let bundle = GoogleTokenBundle(refreshToken: "r1", accessToken: "a1", accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000))
        try vault.saveTokenBundle(bundle, accountID: "acc-1")
        #expect(try vault.loadTokenBundle(accountID: "acc-1") == bundle)
        try vault.deleteTokens(accountID: "acc-1")
        #expect(try vault.loadTokenBundle(accountID: "acc-1") == nil)
    }

    // Access token provider

    @Test func accessTokenProviderUsesCachedTokenWhileFresh() async throws {
        GoogleMockURLProtocol.reset()
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(
            GoogleTokenBundle(refreshToken: "r", accessToken: "cached", accessTokenExpiresAt: fixedNow.addingTimeInterval(3600)),
            accountID: "acc")
        let provider = GoogleAccessTokenProvider(clientID: "cid", vault: vault, client: mockedClient(fixedNow: fixedNow))
        let token = try await provider.accessToken(accountID: "acc")
        #expect(token == "cached")
        #expect(GoogleMockURLProtocol.calls.get().isEmpty) // no network
    }

    @Test func accessTokenProviderRefreshesWhenExpiredAndPersists() async throws {
        GoogleMockURLProtocol.reset()
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(
            GoogleTokenBundle(refreshToken: "r", accessToken: "stale", accessTokenExpiresAt: fixedNow.addingTimeInterval(10)),
            accountID: "acc")
        GoogleMockURLProtocol.setHandler(urlContains: "oauth2.googleapis.com/token") { _ in
            (200, json(#"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer"}"#))
        }
        let provider = GoogleAccessTokenProvider(clientID: "cid", vault: vault, client: mockedClient(fixedNow: fixedNow))
        let token = try await provider.accessToken(accountID: "acc")
        #expect(token == "fresh")
        let updated = try vault.loadTokenBundle(accountID: "acc")
        #expect(updated?.accessToken == "fresh")
        #expect(updated?.refreshToken == "r") // refresh token preserved
        // Refresh request shape: correct endpoint, refresh grant, no client_secret.
        let tokenCalls = GoogleMockURLProtocol.callsMatching("oauth2.googleapis.com/token")
        #expect(tokenCalls.count == 1)
        #expect(tokenCalls[0].body.contains("grant_type=refresh_token"))
        #expect(tokenCalls[0].body.contains("refresh_token=r"))
        #expect(tokenCalls[0].body.contains("client_id=cid"))
        #expect(tokenCalls[0].body.contains("client_secret") == false)
    }

    @Test func accessTokenProviderInvalidGrantKeepsTokensAndFlagsReauth() async throws {
        GoogleMockURLProtocol.reset()
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(GoogleTokenBundle(refreshToken: "r"), accountID: "acc")
        GoogleMockURLProtocol.setHandler(urlContains: "oauth2.googleapis.com/token") { _ in
            (400, json(#"{"error":"invalid_grant"}"#))
        }
        let provider = GoogleAccessTokenProvider(clientID: "cid", vault: vault, client: mockedClient())
        do {
            _ = try await provider.accessToken(accountID: "acc")
            Issue.record("Expected reauthorizationRequired")
        } catch let error as GoogleAccessTokenProvider.ProviderError {
            #expect(error == .reauthorizationRequired)
        }
        // Tokens are NOT silently deleted — the user reconnects explicitly.
        #expect(try vault.loadTokenBundle(accountID: "acc")?.refreshToken == "r")
    }

    // CalendarList

    @Test func calendarListPaginatesAndParses() async throws {
        GoogleMockURLProtocol.reset()
        let page = LockedBox<Int>(0)
        GoogleMockURLProtocol.setHandler(urlContains: "users/me/calendarList") { call in
            let current = page.get() + 1
            page.set(current)
            if current == 1 {
                return (200, json(#"{"items":[{"id":"c1","summary":"Work","accessRole":"owner","primary":true},{"id":"c2","summary":"ReadOnly","accessRole":"reader"}],"nextPageToken":"p2"}"#))
            }
            return (200, json(#"{"items":[{"id":"c3","summary":"Family","accessRole":"writer"}]}"#))
        }
        let client = mockedClient()
        let entries = try await client.listCalendars(accessToken: "at-1")
        #expect(entries.count == 3)
        #expect(entries.filter(\.isWritable).map(\.id) == ["c1", "c3"]) // reader excluded
        #expect(page.get() == 2)
        // Pagination continued with the returned token; Bearer header sent.
        let listCalls = GoogleMockURLProtocol.callsMatching("users/me/calendarList")
        #expect(listCalls.count == 2)
        #expect(listCalls[1].url.contains("pageToken=p2"))
        #expect(listCalls.allSatisfy { $0.authorization == "Bearer at-1" })
    }

    // Event insert

    @Test func insertEventSendsBearerAndParsesID() async throws {
        GoogleMockURLProtocol.reset()
        GoogleMockURLProtocol.setHandler(urlContains: "calendars/cal-9/events") { _ in
            (200, json(#"{"id":"evt-77","kind":"calendar#event","htmlLink":"https://www.google.com/calendar/event?eid=evt-77"}"#))
        }
        let client = mockedClient()
        let inserted = try await client.insertEvent(
            calendarID: "cal-9", title: "Standup",
            start: Date(timeIntervalSince1970: 1_800_000),
            end: Date(timeIntervalSince1970: 1_800_300),
            location: nil, reminderLeadMinutes: 15, accessToken: "at-2")
        #expect(inserted.id == "evt-77")
        #expect(inserted.htmlLink == "https://www.google.com/calendar/event?eid=evt-77")
        let calls = GoogleMockURLProtocol.callsMatching("calendars/cal-9/events")
        #expect(calls.count == 1)
        #expect(calls[0].method == "POST")
        #expect(calls[0].authorization == "Bearer at-2")
        #expect(calls[0].body.contains("\"summary\":\"Standup\""))
    }

    @Test func insertEventHTTPErrorThrows() async throws {
        GoogleMockURLProtocol.reset()
        GoogleMockURLProtocol.setHandler(urlContains: "calendars/cal-x/events") { _ in
            (403, json(#"{"error":{"code":403,"message":"Google Calendar API has not been used...","errors":[{"reason":"accessNotConfigured","domain":"usageLimits","message":"Google Calendar API has not been used..."}],"status":"PERMISSION_DENIED"}}"#))
        }
        let client = mockedClient()
        do {
            _ = try await client.insertEvent(
                calendarID: "cal-x", title: "T",
                start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
                location: nil, accessToken: "at")
            Issue.record("Expected http error")
        } catch let error as GoogleAPIError {
            // Structured evidence is preserved (sanitized codes only) — the
            // free-text message never reaches the error.
            #expect(error == .http(status: 403, reason: "accessNotConfigured", googleStatus: "PERMISSION_DENIED"))
            #expect(error.failureCategory == .apiNotEnabled)
        }
    }

    // Event body mapping (timezone / location / validation)

    @Test func eventBodyMapsTimezoneAndOmitsEmptyLocation() throws {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let start = Date(timeIntervalSince1970: 1_800_000)
        let body = try GoogleEventBodyBuilder.body(
            title: "  Standup  ", start: start, end: start.addingTimeInterval(1800),
            location: "   ", timeZone: tz)
        let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(root?["summary"] as? String == "Standup")
        #expect(root?["location"] == nil)
        let startObj = root?["start"] as? [String: Any]
        #expect(startObj?["timeZone"] as? String == "Australia/Sydney")
        let dateTime = startObj?["dateTime"] as? String ?? ""
        #expect(dateTime.hasSuffix("+11:00") || dateTime.hasSuffix("+10:00"))
    }

    @Test func eventBodyRejectsEmptyTitleAndBadRange() {
        let start = Date(timeIntervalSince1970: 1_800_000)
        #expect(throws: GoogleAPIError.invalidEvent) {
            _ = try GoogleEventBodyBuilder.body(title: "  ", start: start, end: start.addingTimeInterval(60), location: nil)
        }
        #expect(throws: GoogleAPIError.invalidEvent) {
            _ = try GoogleEventBodyBuilder.body(title: "T", start: start, end: start, location: nil)
        }
    }

    @Test func rfc3339ParsesFractionalSecondsAndOffsets() {
        let parsed = GoogleRFC3339.date(fromRFC3339: "2026-11-06T15:04:05.123+11:00")
        #expect(parsed != nil)
        #expect(GoogleRFC3339.date(fromRFC3339: "2026-11-06T15:04:05+11:00") != nil)
        #expect(GoogleRFC3339.date(fromRFC3339: "not-a-date") == nil)
        // Stability: format → parse round-trips to the same second.
        if let parsed {
            let reformatted = GoogleRFC3339.string(from: parsed, timeZone: TimeZone(identifier: "Australia/Sydney")!)
            #expect(GoogleRFC3339.date(fromRFC3339: reformatted) == parsed)
        }
    }

    @Test func idTokenParsesEmailAndSub() {
        let payload = #"{"email":"fin@example.com","sub":"1234567890"}"#
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(b64).signature"
        let identity = GoogleTokenResponseParser.parseIDToken(token)
        #expect(identity.email == "fin@example.com")
        #expect(identity.sub == "1234567890")
        #expect(GoogleTokenResponseParser.parseIDToken("garbage").email == nil)
    }

    // Google write coordinator

    @MainActor
    @Test func coordinatorExactMatchBlocksUnlessArmed() async {
        let sink = MockGoogleSink()
        let draft = makeDraft()
        sink.exactMatches = ["Standup|\(String(draft.start.timeIntervalSince1970))"]

        let blocked = await GoogleWriteCoordinator.write(drafts: [draft], calendarID: "cal", sink: sink)
        #expect(blocked.outcomes[draft.id] == .exactMatchNeedsConfirmation)
        #expect(sink.insertCount == 0) // fail-closed: no write on duplicate

        var armed = draft
        armed.duplicateAddArmed = true
        let allowed = await GoogleWriteCoordinator.write(drafts: [armed], calendarID: "cal", sink: sink)
        #expect(allowed.outcomes[armed.id] == .created(id: "evt-1"))
        #expect(allowed.anySaved)
    }

    @MainActor
    @Test func coordinatorPerEventFailureDoesNotUndoEarlierSuccess() async {
        let sink = MockGoogleSink()
        let first = makeDraft(title: "One")
        let second = makeDraft(title: "Two")
        let third = makeDraft(title: "Three")
        sink.insertResults = [
            .success(GoogleInsertedEvent(id: "evt-1")),
            .failure(GoogleAPIError.http(status: 403)),
            .success(GoogleInsertedEvent(id: "evt-3"))
        ]
        let result = await GoogleWriteCoordinator.write(drafts: [first, second, third], calendarID: "cal", sink: sink)
        #expect(result.outcomes[first.id] == .created(id: "evt-1")) // stays saved
        #expect(result.outcomes[second.id] == .failed("Google Calendar API error (HTTP 403)."))
        #expect(result.outcomes[third.id] == .created(id: "evt-3"))
        #expect(result.anySaved && result.anyFailed)
        #expect(sink.insertCount == 3) // remaining drafts still attempted
    }

    @MainActor
    @Test func coordinatorNetworkErrorIsCommitUncertain() async {
        let sink = MockGoogleSink()
        let draft = makeDraft()
        sink.insertResults = [.failure(GoogleAPIError.network("connection lost"))]
        let result = await GoogleWriteCoordinator.write(drafts: [draft], calendarID: "cal", sink: sink)
        if case .commitUncertain = result.outcomes[draft.id] {
            // expected
        } else {
            Issue.record("Expected commitUncertain, got \(String(describing: result.outcomes[draft.id]))")
        }
        #expect(result.anySaved == false)
        #expect(result.anyFailed)
    }

    @MainActor
    @Test func coordinatorProbeFailureIsFailClosed() async {
        let sink = MockGoogleSink()
        let draft = makeDraft()
        sink.probeError = GoogleAPIError.network("probe lost")
        let result = await GoogleWriteCoordinator.write(drafts: [draft], calendarID: "cal", sink: sink)
        #expect(result.outcomes[draft.id] == .failed("Network error: probe lost"))
        #expect(sink.insertCount == 0) // never write without the duplicate check
    }

    @MainActor
    @Test func coordinatorSkipsSavedAndBlockedDrafts() async {
        let sink = MockGoogleSink()
        var saved = makeDraft(title: "Saved")
        saved.savedEventID = "evt-0"
        var blocked = makeDraft(title: "Blocked")
        blocked.issues = [ValidationIssue(kind: .ampmAmbiguous, message: "am or pm?", blocking: true)]
        let ok = makeDraft(title: "Ok")
        let result = await GoogleWriteCoordinator.write(drafts: [saved, blocked, ok], calendarID: "cal", sink: sink)
        #expect(result.outcomes[saved.id] == .alreadySaved(id: "evt-0"))
        #expect(result.outcomes[blocked.id] == .failed("Not ready to add yet."))
        #expect(result.outcomes[ok.id] == .created(id: "evt-1"))
        #expect(sink.probeCount == 1) // only the addable draft was probed
    }

    // Scopes & config invariants

    @Test func scopesAreMinimalAndCoverCalendarList() {
        let scopes = GoogleAuthorizationScopes.requested
        #expect(scopes.contains(OAuthAuthorizationURLBuilder.calendarEventsScope))
        #expect(scopes.contains(OAuthAuthorizationURLBuilder.calendarReadonlyScope))
        #expect(scopes.contains("openid email"))
        #expect(scopes.count == 3) // no broad `calendar` full-access scope
        let pkce = OAuthPKCE.make()
        let url = OAuthAuthorizationURLBuilder.authorizationURL(
            clientID: "c", redirectURI: "http://127.0.0.1:53682/oauth/callback", pkce: pkce)!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let scopeParam = q.first { $0.name == "scope" }!.value!
        #expect(scopeParam.contains("calendar.events"))
        #expect(scopeParam.contains("calendar.readonly"))
        #expect(!scopeParam.contains("auth/calendar ")) // no full-calendar scope
    }

    // Branding regression (owner decision 2026-11-06: app renamed to QuikCal)

    @Test func brandingIsQuikCalWithStableInternalIDs() {
        #expect(AppBranding.displayName == "QuikCal") // exact capitalization
        #expect(AppBranding.legacyName == "Quiet Calendar")
        // Stable identity — never renamed with the display brand:
        #expect(GoogleTokenKeychainAccount.service == "com.quietcalendar.app.google-oauth")
        #expect(GoogleOAuthClientConfig().redirectURI == "http://127.0.0.1:53682/oauth/callback")
        #expect(GoogleOAuthClientConfig().loopbackPort == 53682)
        #expect(AccessibilityDragGuideCopy.appFileName == "QuikCal.app")
        #expect(AccessibilityDragGuidePolicy.expectedDisplayName == "QuikCal")
    }
}
