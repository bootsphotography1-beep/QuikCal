import Foundation

// MARK: - Models

/// One entry from the Google CalendarList. Only writable entries are offered
/// as write destinations (`accessRole` owner/writer/writerWithoutPrivateAccess).
public struct GoogleCalendarListEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var summary: String
    public var accessRole: String
    public var primary: Bool
    public var timeZone: String?

    public init(id: String, summary: String, accessRole: String, primary: Bool = false, timeZone: String? = nil) {
        self.id = id
        self.summary = summary
        self.accessRole = accessRole
        self.primary = primary
        self.timeZone = timeZone
    }

    /// Writable per Google access roles. `reader`/`freeBusyReader` are never
    /// offered as a write destination — no silent writes to read-only calendars.
    public var isWritable: Bool {
        switch accessRole {
        case "owner", "writer", "writerWithoutPrivateAccess": return true
        default: return false
        }
    }
}

public enum GoogleCalendarListParser: Sendable {
    /// Parses one CalendarList page. Tolerates missing per-item fields;
    /// entries without an id are dropped.
    public static func parsePage(_ data: Data) throws -> (items: [GoogleCalendarListEntry], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard root["error"] == nil else { throw GoogleAPIError.invalidResponse }
        let rawItems = root["items"] as? [[String: Any]] ?? []
        let items: [GoogleCalendarListEntry] = rawItems.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return GoogleCalendarListEntry(
                id: id,
                summary: (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? id,
                accessRole: item["accessRole"] as? String ?? "reader",
                primary: item["primary"] as? Bool ?? false,
                timeZone: item["timeZone"] as? String
            )
        }
        return (items, root["nextPageToken"] as? String)
    }
}

/// Minimal event summary used for the exact-match (duplicate) probe and
/// the delete candidate lookup.
public struct GoogleEventSummary: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Start instant; nil only for unparseable entries (never matched).
    public var start: Date?
    /// End instant (parsed for the delete flow's candidate details).
    public var end: Date?
    public var location: String?
    /// Set when this entry is an instance of a recurring event
    /// (`singleEvents=true` expansion). Recurring targets are never
    /// deletable by QuikCal — this flag marks them at lookup time.
    public var recurringEventId: String?
    /// True when the resource itself carries `recurrence` rules (a series
    /// MASTER, e.g. from `events.get`). Defense in depth beyond
    /// `recurringEventId`: a master fetched by ID must never be treated
    /// as a plain single event. (Review hardening 2026-11-07.)
    public var hasRecurrenceRules: Bool
    /// The resource etag. When present, `events.delete` is sent with
    /// `If-Match` so a concurrent edit since revalidation is a definite
    /// 412 rejection instead of deleting a changed event. (Review
    /// hardening 2026-11-07 — Google "Get specific versions of
    /// resources" documents If-Match for update AND delete.)
    public var etag: String?

    public init(
        id: String,
        title: String,
        start: Date?,
        end: Date? = nil,
        location: String?,
        recurringEventId: String? = nil,
        hasRecurrenceRules: Bool = false,
        etag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.recurringEventId = recurringEventId
        self.hasRecurrenceRules = hasRecurrenceRules
        self.etag = etag
    }
}

public enum GoogleEventsParser: Sendable {
    public static func parsePage(_ data: Data) throws -> (items: [GoogleEventSummary], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard root["error"] == nil else { throw GoogleAPIError.invalidResponse }
        let rawItems = root["items"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { item -> GoogleEventSummary? in
            guard let id = item["id"] as? String else { return nil }
            let start = (item["start"] as? [String: Any]).flatMap(Self.date(from:))
            let end = (item["end"] as? [String: Any]).flatMap(Self.date(from:))
            return GoogleEventSummary(
                id: id,
                title: item["summary"] as? String ?? "",
                start: start,
                end: end,
                location: item["location"] as? String,
                recurringEventId: item["recurringEventId"] as? String,
                hasRecurrenceRules: Self.hasRecurrenceRules(item),
                etag: item["etag"] as? String
            )
        }
        return (items, root["nextPageToken"] as? String)
    }

    /// Parses a single events.get resource (same field contract as a page item).
    public static func parseEvent(_ data: Data) throws -> GoogleEventSummary {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard root["error"] == nil else { throw GoogleAPIError.invalidResponse }
        guard let id = root["id"] as? String, !id.isEmpty else {
            throw GoogleAPIError.invalidResponse
        }
        let start = (root["start"] as? [String: Any]).flatMap(Self.date(from:))
        let end = (root["end"] as? [String: Any]).flatMap(Self.date(from:))
        return GoogleEventSummary(
            id: id,
            title: root["summary"] as? String ?? "",
            start: start,
            end: end,
            location: root["location"] as? String,
            recurringEventId: root["recurringEventId"] as? String,
            hasRecurrenceRules: Self.hasRecurrenceRules(root),
            etag: root["etag"] as? String
        )
    }

    /// A non-empty `recurrence` array (RRULE/RDATE/EXDATE strings) means
    /// this resource is a recurring-series master. Instances carry
    /// `recurringEventId` instead; masters carry `recurrence` — both are
    /// recurring, neither is deletable by QuikCal.
    private static func hasRecurrenceRules(_ item: [String: Any]) -> Bool {
        guard let rules = item["recurrence"] as? [Any] else { return false }
        return !rules.isEmpty
    }

    /// Accepts `dateTime` (RFC 3339) or all-day `date` (interpreted midnight UTC —
    /// display-only for probes; QuikCal drafts are timed events).
    public static func date(from start: [String: Any]) -> Date? {
        if let dateTime = start["dateTime"] as? String {
            return GoogleRFC3339.date(fromRFC3339: dateTime)
        }
        if let date = start["date"] as? String {
            return GoogleRFC3339.date(fromRFC3339: date + "T00:00:00Z")
        }
        return nil
    }
}

public enum GoogleEventIDParser: Sendable {
    /// events.insert returns the created event resource; we need its id.
    public static func parseCreatedEventID(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard let id = root["id"] as? String, !id.isEmpty else {
            throw GoogleAPIError.invalidResponse
        }
        return id
    }

    /// The full persisted result of `events.insert`: the created event's id
    /// plus Google's own `htmlLink` (the official event URL from the insert
    /// response — never a locally guessed/composed link).
    public static func parseCreatedEvent(_ data: Data) throws -> GoogleInsertedEvent {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard let id = root["id"] as? String, !id.isEmpty else {
            throw GoogleAPIError.invalidResponse
        }
        let htmlLink = (root["htmlLink"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GoogleInsertedEvent(id: id, htmlLink: htmlLink)
    }
}

/// The persisted result of one Google `events.insert`.
public struct GoogleInsertedEvent: Sendable, Equatable {
    public var id: String
    public var htmlLink: String?

    public init(id: String, htmlLink: String? = nil) {
        self.id = id
        self.htmlLink = htmlLink
    }
}

// MARK: - Time formatting

public enum GoogleRFC3339: Sendable {
    /// RFC 3339 with local UTC offset, e.g. 2026-11-06T15:04:05+11:00.
    /// Google accepts offsets; the explicit `timeZone` field keeps the event
    /// rendering in the user's zone.
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absOffset = abs(offsetSeconds)
        let hh = absOffset / 3600, mm = (absOffset % 3600) / 60
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 1970, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, hh, mm
        )
    }

    public static func date(fromRFC3339 value: String) -> Date? {
        // Normalize fractional seconds (e.g. .123) which DateFormatter lacks here.
        var trimmed = value
        if let tRange = trimmed.range(of: "T"),
           let dotRange = trimmed.range(of: ".", options: [], range: trimmed.index(after: tRange.lowerBound)..<trimmed.endIndex) {
            var digitEnd = trimmed.index(after: dotRange.lowerBound)
            while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber { digitEnd = trimmed.index(after: digitEnd) }
            // Remove the dot AND its digits: 15:04:05.123+11:00 → 15:04:05+11:00
            trimmed.removeSubrange(dotRange.lowerBound..<digitEnd)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.isLenient = false
        return formatter.date(from: trimmed)
    }
}

// MARK: - Event JSON

/// Builds the events.insert request body from a confirmed draft.
/// Timed events only — drafts carry no all-day flag, so none is invented.
public enum GoogleEventBodyBuilder: Sendable {
    public static func body(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String? = nil,
        reminderLeadMinutes: Int? = nil,
        timeZone: TimeZone = .current
    ) throws -> Data {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw GoogleAPIError.invalidEvent }
        guard end > start else { throw GoogleAPIError.invalidEvent }
        var object: [String: Any] = [
            "summary": trimmedTitle,
            "start": [
                "dateTime": GoogleRFC3339.string(from: start, timeZone: timeZone),
                "timeZone": timeZone.identifier
            ],
            "end": [
                "dateTime": GoogleRFC3339.string(from: end, timeZone: timeZone),
                "timeZone": timeZone.identifier
            ]
        ]
        if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            object["location"] = location
        }
        // Description (0.3.17): the reviewed user detail persists to the
        // SAME value the confirmation card showed. Omitted entirely when
        // none was provided — never invented filler.
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            object["description"] = notes
        }
        // Reminder: attached to the event (Google's `minutes` is inherently
        // relative to the event start) — the start/end above are never
        // shifted. ONLY a user-specified reminder produces a `reminders`
        // object, with `useDefault: false` so the explicit value wins. No
        // reminder requested → the key is omitted entirely, leaving the
        // calendar's default reminders untouched (never silently disabled).
        if let reminderLeadMinutes {
            guard (0...EventDraftResolver.maximumReminderLeadMinutes).contains(reminderLeadMinutes) else {
                throw GoogleAPIError.invalidEvent
            }
            object["reminders"] = [
                "useDefault": false,
                "overrides": [
                    ["method": "popup", "minutes": reminderLeadMinutes]
                ]
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}

// MARK: - Token responses

public struct GoogleAccessGrant: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date
    /// Refresh tokens are long-lived; Google may rotate on re-consent only.
    public var grantedScopes: [String]

    public init(accessToken: String, expiresAt: Date, grantedScopes: [String] = []) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }
}

public enum GoogleTokenResponseParser: Sendable {
    /// Parses a token-endpoint success body (authorization-code or refresh grant).
    public static func parseAccessGrant(_ data: Data, now: Date) throws -> GoogleAccessGrant {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        guard let access = root["access_token"] as? String, !access.isEmpty else {
            throw GoogleAPIError.invalidResponse
        }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue
            ?? Double(root["expires_in"] as? String ?? "3600") ?? 3600
        let scopes = (root["scope"] as? String ?? "")
            .split(separator: " ").map(String.init)
        return GoogleAccessGrant(
            accessToken: access,
            expiresAt: now.addingTimeInterval(expiresIn),
            grantedScopes: scopes
        )
    }

    /// Extracts `email` and `sub` from an id_token payload (no signature check —
    /// the token arrives directly from the TLS-protected token endpoint).
    public static func parseIDToken(_ idToken: String) -> (email: String?, sub: String?) {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (root["email"] as? String, root["sub"] as? String)
    }
}

// MARK: - Errors

/// The structured evidence parsed from a Google HTTP error payload —
/// `error.errors[0].reason` and `error.status`. Only these short
/// Google-authored codes are kept; the free-text `error.message` (which can
/// embed project/account details and URLs) is deliberately NOT captured, so
/// no account payload can leak into UI or logs.
public struct GoogleHTTPFailure: Sendable, Equatable {
    public var status: Int
    /// e.g. "accessNotConfigured", "insufficientPermissions".
    public var reason: String?
    /// e.g. "PERMISSION_DENIED", "RESOURCE_EXHAUSTED".
    public var googleStatus: String?

    public init(status: Int, reason: String? = nil, googleStatus: String? = nil) {
        self.status = status
        self.reason = reason
        self.googleStatus = googleStatus
    }
}

public enum GoogleErrorPayloadParser: Sendable {
    /// Parses Google's structured error payload. Tolerant: missing or
    /// non-structured bodies produce no reason (never a guess).
    public static func parse(status: Int, data: Data) -> GoogleHTTPFailure {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return GoogleHTTPFailure(status: status)
        }
        let reason = (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first
        let googleStatus = error["status"] as? String
        return GoogleHTTPFailure(status: status, reason: reason, googleStatus: googleStatus)
    }
}

/// Actionable, evidence-based classification of a Google Calendar API
/// failure. Categories are derived ONLY from the structured payload (HTTP
/// status + `reason`/`status` codes); an unrecognized 403 is honestly
/// `unclassified` — the cause is NEVER guessed.
public enum GoogleCalendarFailureCategory: Sendable, Equatable, Codable {
    /// `accessNotConfigured` — the Google Calendar API is disabled for the
    /// OAuth client's Google Cloud project (the classic structured 403).
    case apiNotEnabled
    /// `insufficientPermissions` — the granted scopes don't cover the request.
    case insufficientPermissions
    /// Quota / rate-limit reasons (`quotaExceeded`, `dailyLimitExceeded`,
    /// `userRateLimitExceeded`, `rateLimitExceeded`, `servingLimitExceeded`).
    case quotaOrRateLimit
    /// HTTP 401 — the stored sign-in was rejected (expired/revoked token).
    case authenticationRejected
    /// Anything else — honest unknown; the response carried no recognized
    /// structured reason.
    case unclassified(status: Int)

    public static func classify(status: Int, reason: String?, googleStatus: String? = nil) -> GoogleCalendarFailureCategory {
        switch reason {
        case "accessNotConfigured":
            return .apiNotEnabled
        case "insufficientPermissions":
            return .insufficientPermissions
        case "quotaExceeded", "dailyLimitExceeded", "userRateLimitExceeded",
             "rateLimitExceeded", "servingLimitExceeded":
            return .quotaOrRateLimit
        default:
            if status == 401 { return .authenticationRejected }
            return .unclassified(status: status)
        }
    }

    public static func classify(_ failure: GoogleHTTPFailure) -> GoogleCalendarFailureCategory {
        classify(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
    }

    /// Sanitized, actionable user copy. Contains no tokens, no account
    /// payload, no raw Google message text — only the category's fix.
    public var userFacingMessage: String {
        switch self {
        case .apiNotEnabled:
            return "Google Calendar API is turned off for this app's Google Cloud project. Enable “Google Calendar API” in Google Cloud Console (APIs & Services → Library) for the OAuth client's project, then press Refresh calendars."
        case .insufficientPermissions:
            return "The signed-in Google account hasn't granted this app the permission this request needs. Sign in again in Settings and grant the requested calendar access — QuikCal never changes scopes by itself."
        case .quotaOrRateLimit:
            return "Google is rate-limiting or quota-limiting this app right now. Wait a moment, then press Refresh calendars."
        case .authenticationRejected:
            return "Google rejected the stored sign-in. Sign in again in Settings."
        case .unclassified(let status):
            return "Google returned HTTP \(status) without a recognized structured reason — the exact cause isn't visible to QuikCal. Press Refresh calendars to retry, or reconnect the account in Settings."
        }
    }
}

/// Structured calendar-list load failure surfaced to the UI: a safe
/// category plus its sanitized message. The raw response body, tokens and
/// account payload never reach this type.
public struct GoogleCalendarListFailure: Sendable, Equatable, Codable {
    public var category: GoogleCalendarFailureCategory
    public var message: String

    public init(category: GoogleCalendarFailureCategory, message: String) {
        self.category = category
        self.message = message
    }
}

public enum GoogleAPIError: Error, Equatable, LocalizedError {
    /// Refresh token rejected (revoked/expired) — the account must re-consent.
    case invalidGrant
    /// Non-2xx HTTP response. `reason`/`googleStatus` carry the structured
    /// evidence from Google's error payload when it provided one (sanitized
    /// codes only — no message text, no account payload).
    case http(status: Int, reason: String? = nil, googleStatus: String? = nil)
    case network(String)
    case invalidResponse
    case invalidEvent
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidGrant: return "Google access was revoked or expired. Sign in again."
        case .http(let status, let reason, _):
            if let reason { return "Google Calendar API error (HTTP \(status), \(reason))." }
            return "Google Calendar API error (HTTP \(status))."
        case .network(let message): return "Network error: \(message)"
        case .invalidResponse: return "Unexpected response from Google."
        case .invalidEvent: return "The event is not valid for Google Calendar."
        case .notConfigured: return "Google OAuth is not configured."
        }
    }

    /// Evidence-based category for this failure; `.unclassified` when the
    /// response carried no recognized structured reason (never guessed).
    public var failureCategory: GoogleCalendarFailureCategory {
        if case .http(let status, let reason, let googleStatus) = self {
            return GoogleCalendarFailureCategory.classify(status: status, reason: reason, googleStatus: googleStatus)
        }
        return .unclassified(status: -1)
    }
}

// MARK: - Client

/// Thin Google Calendar REST client. Injectable session + clock for mocked
/// tests; no tokens are logged. Scopes: `calendar.events` (insert + event
/// read for the duplicate probe) and `calendar.readonly` (CalendarList).
public struct GoogleCalendarClient: Sendable {
    public static let calendarBase = URL(string: "https://www.googleapis.com/calendar/v3")!
    public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// Hard page cap so a hostile/looping nextPageToken can never hang a write.
    public static let maxPages = 10

    public var session: URLSession
    public var now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    // CalendarList (requires calendar.readonly or broader)

    public func listCalendars(accessToken: String) async throws -> [GoogleCalendarListEntry] {
        var all: [GoogleCalendarListEntry] = []
        var pageToken: String? = nil
        for _ in 0..<Self.maxPages {
            var components = URLComponents(url: Self.calendarBase.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            let data = try await authorizedGET(url: components.url!, accessToken: accessToken)
            let (items, next) = try GoogleCalendarListParser.parsePage(data)
            all.append(contentsOf: items)
            guard let next, !next.isEmpty else { return all }
            pageToken = next
        }
        return all
    }

    // Events (calendar.events scope)

    public func insertEvent(
        calendarID: String,
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String? = nil,
        reminderLeadMinutes: Int? = nil,
        accessToken: String
    ) async throws -> GoogleInsertedEvent {
        let body = try GoogleEventBodyBuilder.body(
            title: title, start: start, end: end, location: location,
            notes: notes, reminderLeadMinutes: reminderLeadMinutes)
        var request = URLRequest(url: Self.calendarBase
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleErrorPayloadParser.parse(status: http.statusCode, data: data)
            throw GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
        }
        return try GoogleEventIDParser.parseCreatedEvent(data)
    }

    /// Exact-match probe window: drafts are matched against events starting in
    /// [start - 1s, start + 1s] so equal wall-clock times compare equal.
    public func listEventsNear(
        calendarID: String,
        start: Date,
        end: Date,
        accessToken: String
    ) async throws -> [GoogleEventSummary] {
        var components = URLComponents(url: Self.calendarBase
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: GoogleRFC3339.string(from: start.addingTimeInterval(-1))),
            URLQueryItem(name: "timeMax", value: GoogleRFC3339.string(from: end.addingTimeInterval(1))),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        var all: [GoogleEventSummary] = []
        var pageToken: String? = nil
        for _ in 0..<Self.maxPages {
            if let pageToken {
                var comps = components
                comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: pageToken)]
                components = comps
            }
            let data = try await authorizedGET(url: components.url!, accessToken: accessToken)
            let (items, next) = try GoogleEventsParser.parsePage(data)
            all.append(contentsOf: items)
            guard let next, !next.isEmpty else { return all }
            pageToken = next
        }
        return all
    }

    // Token endpoint

    /// events.get — one event by ID on one calendar. Nil when the event no
    /// longer exists (HTTP 404/410). Used by the delete flow's revalidation
    /// and verified reconciliation. Requires the same `calendar.events`
    /// scope already granted for Add (events.list/events.delete are part
    /// of that scope — no scope change).
    public func getEvent(
        calendarID: String,
        eventID: String,
        accessToken: String
    ) async throws -> GoogleEventSummary? {
        let url = Self.calendarBase
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
            .appendingPathComponent(eventID)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        if http.statusCode == 404 || http.statusCode == 410 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleErrorPayloadParser.parse(status: http.statusCode, data: data)
            throw GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
        }
        return try GoogleEventsParser.parseEvent(data)
    }

    /// events.delete — deletes ONE event by its ID. Success = any 2xx
    /// (Google returns 200 with an empty body or 204). HTTP 404/410 means
    /// the event is already gone (definite not-found failure for a
    /// revalidated target). A network error AFTER the request was sent is
    /// an unknown outcome — thrown as `GoogleAPIError.network` so callers
    /// map it to the uncertain path (never a blind retry).
    ///
    /// When `ifMatch` (the etag from the revalidating `events.get`) is
    /// supplied, the request is conditional: HTTP 412 means the event
    /// changed since revalidation — a definite "stale target" rejection
    /// that the caller maps to the honest changed-target copy. This
    /// closes the read→delete TOCTOU window the snapshot comparison alone
    /// cannot (e.g. a concurrent description-only edit).
    public func deleteEvent(
        calendarID: String,
        eventID: String,
        accessToken: String,
        ifMatch: String? = nil
    ) async throws {
        let url = Self.calendarBase
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
            .appendingPathComponent(eventID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let ifMatch, !ifMatch.isEmpty {
            request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        if http.statusCode == 404 || http.statusCode == 410 {
            throw GoogleAPIError.http(status: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleErrorPayloadParser.parse(status: http.statusCode, data: data)
            throw GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
        }
    }

    public func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String = ""
    ) async throws -> GoogleAccessGrant {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleAPIError.notConfigured
        }
        var request = URLRequest(url: OAuthAuthorizationURLBuilder.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleRefreshTokenRequest.formBody(
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret
        )
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        if http.statusCode == 400 || http.statusCode == 401 { throw GoogleAPIError.invalidGrant }
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleErrorPayloadParser.parse(status: http.statusCode, data: data)
            throw GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
        }
        return try GoogleTokenResponseParser.parseAccessGrant(data, now: now())
    }

    /// Best-effort revoke. HTTP 400 commonly means "already revoked" — treated
    /// as success; local tokens are deleted regardless by the caller.
    public func revoke(token: String) async {
        var request = URLRequest(url: Self.revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(Self.formEncode(token))".utf8)
        _ = try? await perform(request)
    }

    // Plumbing

    private func authorizedGET(url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleErrorPayloadParser.parse(status: http.statusCode, data: data)
            throw GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw GoogleAPIError.network(error.localizedDescription)
        }
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum GoogleRefreshTokenRequest: Sendable {
    /// `clientSecret` is included ONLY when non-empty — Google's token
    /// endpoint enforces the secret for Desktop clients on the refresh
    /// grant as well (same 2026-11-06 verified behavior as the code
    /// exchange).
    public static func formBody(
        refreshToken: String,
        clientID: String,
        clientSecret: String = ""
    ) -> Data {
        var pairs: [(String, String)] = [
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            pairs.append(("client_secret", secret))
        }
        let encoded = pairs.map { "\($0.0)=\(GoogleCalendarClient.formEncode($0.1))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
