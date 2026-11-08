import Foundation
import QuietCalendarCore

/// Google-side write sink for the confirmed Add flow. Every call goes through
/// the access-token provider (refresh on expiry); nothing is written without
/// the caller (ViewModel) having resolved an explicit Google destination.
@MainActor
final class GoogleCalendarWriteSink: GoogleWriteCoordinator.Sink, EventDeleteSink {
    let accountID: String
    /// Display name of the target calendar (delete-flow reviewed target).
    var calendarSummary: String
    private let provider: GoogleAccessTokenProvider
    private let client: GoogleCalendarClient
    /// Invoked when the access-token provider reports `invalid_grant` so the
    /// app can flag the account as needing re-consent (UI gate closes).
    private let onReauthRequired: (() -> Void)?

    init(
        accountID: String,
        clientID: String,
        /// Same enforced token-endpoint secret as the code exchange (env
        /// `QUIET_CALENDAR_GOOGLE_CLIENT_SECRET`); sent only when non-empty,
        /// never bundled, never logged.
        clientSecret: String = "",
        vault: GoogleTokenVault,
        client: GoogleCalendarClient = GoogleCalendarClient(),
        calendarSummary: String = "",
        onReauthRequired: (() -> Void)? = nil
    ) {
        self.accountID = accountID
        self.calendarSummary = calendarSummary
        // 0.3.12 review fix: thread the secret into the token provider so
        // refresh grants (actual writes) match the code exchange behavior.
        self.provider = GoogleAccessTokenProvider(
            clientID: clientID, clientSecret: clientSecret, vault: vault, client: client)
        self.client = client
        self.onReauthRequired = onReauthRequired
    }

    private func accessToken() async throws -> String {
        do {
            return try await provider.accessToken(accountID: accountID)
        } catch let error as GoogleAccessTokenProvider.ProviderError
        where error == .reauthorizationRequired {
            onReauthRequired?()
            throw error
        }
    }

    func hasExactMatch(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        calendarID: String
    ) async throws -> Bool {
        let access = try await accessToken()
        let near = try await client.listEventsNear(
            calendarID: calendarID, start: start, end: end, accessToken: access)
        let wantedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return near.contains { event in
            guard event.title == title else { return false }
            guard let eventStart = event.start, abs(eventStart.timeIntervalSince(start)) <= 1 else { return false }
            let eventLocation = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return eventLocation == wantedLocation
        }
    }

    func insertEvent(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?,
        reminderLeadMinutes: Int?,
        calendarID: String
    ) async throws -> GoogleInsertedEvent {
        let access = try await accessToken()
        return try await client.insertEvent(
            calendarID: calendarID,
            title: title,
            start: start,
            end: end,
            location: location,
            notes: notes,
            reminderLeadMinutes: reminderLeadMinutes,
            accessToken: access
        )
    }

    // MARK: - EventDeleteSink (voice delete; explicit-confirm flow only)

    /// Candidate lookup via `events.list` in the query's bounded window.
    /// The already-granted `calendar.events` scope covers this read; no
    /// scope or login change. Recurring instances (singleEvents expansion
    /// carrying `recurringEventId`) are marked and excluded by the
    /// coordinator — never silently deletable.
    func fetchCandidates(for query: EventLookupQuery) async throws -> [EventCandidate] {
        let access = try await accessToken()
        let events = try await client.listEventsNear(
            calendarID: query.calendarID,
            start: query.windowStart,
            end: query.windowEnd,
            accessToken: access
        )
        return events.map { event in
            let start = event.start ?? Date.distantPast
            return EventCandidate(
                id: event.id,
                provider: .google,
                calendarID: query.calendarID,
                calendarTitle: query.calendarTitle,
                title: event.title,
                start: start,
                end: event.end ?? start,
                isRecurring: event.recurringEventId != nil || event.hasRecurrenceRules,
                location: event.location,
                etag: event.etag
            )
        }
    }

    /// Re-fetch one Google event by ID (events.get). Nil when gone.
    func refetch(provider: DeleteProvider, calendarID: String, eventID: String) async throws -> EventCandidate? {
        guard provider == .google else { return nil }
        let access = try await accessToken()
        guard let event = try await client.getEvent(
            calendarID: calendarID,
            eventID: eventID,
            accessToken: access
        ) else {
            return nil
        }
        let start = event.start ?? Date.distantPast
        return EventCandidate(
            id: event.id,
            provider: .google,
            calendarID: calendarID,
            calendarTitle: calendarSummary,
            title: event.title,
            start: start,
            end: event.end ?? start,
            isRecurring: event.recurringEventId != nil || event.hasRecurrenceRules,
            location: event.location,
            etag: event.etag
        )
    }

    /// Delete ONE Google event by ID (events.delete). The revalidated
    /// candidate's etag is sent as `If-Match` so a concurrent edit since
    /// revalidation is a definite 412 rejection (stale target), not a
    /// delete of a changed event. Definite failures throw; an
    /// unknown-outcome network failure after send throws
    /// `DeleteUncertainError` so the coordinator reconciles by re-probe
    /// and never blind-retries.
    func delete(candidate: EventCandidate) async throws {
        let access = try await accessToken()
        do {
            try await client.deleteEvent(
                calendarID: candidate.calendarID,
                eventID: candidate.id,
                accessToken: access,
                ifMatch: candidate.etag
            )
        } catch let error as GoogleAPIError {
            if case .network(let message) = error {
                throw DeleteUncertainError(message: message)
            }
            if case .http(let status, _, _) = error, status == 412 {
                // Definite precondition failure: the event changed since
                // the revalidating fetch. Nothing was deleted.
                throw DeleteUnavailableError(message: DeleteFlowCopy.staleTarget)
            }
            if case .http(let status, _, _) = error, status == 404 || status == 410 {
                throw DeleteUnavailableError(message: "The event is no longer on this Google calendar.")
            }
            throw error
        }
    }
}
