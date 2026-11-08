import Foundation
import EventKit
import QuietCalendarCore

enum CalendarServiceError: LocalizedError {
    case calendarUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .calendarUnavailable:
            return "That calendar is no longer writable. Choose another calendar."
        case .saveFailed(let message):
            return message
        }
    }
}

/// Thin, read/write EventKit wrapper. It never deletes anything outside the
/// explicit delete flow (lookup → review → confirm → revalidate) and never
/// asks for access by itself: `requestFullAccess()` is only called from an
/// explicit button. Reads use `store`; the write batch uses a dedicated
/// `writeStore` so a batch `reset()` discards only this batch's staged
/// work — never read state or another store's pending work.
@MainActor
final class CalendarService: CalendarEventSink, CalendarWriteSink, EventDeleteSink {
    private let store = EKEventStore()
    private let writeStore = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Whether EventKit permits event READS under the current grant.
    /// Full access can read; write-only cannot (it may also refuse
    /// `calendar(withIdentifier:)` even though the default calendar is
    /// authorized and writable — see `writableCalendar(forWritingWithID:)`).
    private var canReadEvents: Bool {
        switch authorizationStatus {
        case .fullAccess: return true
        case .notDetermined, .restricted, .denied, .writeOnly: return false
        @unknown default: return false
        }
    }

    /// Honest duplicate-detection capability (2026-11-07 review): under
    /// WRITE-ONLY EventKit permits no event reads, so `hasExactMatch` can
    /// verify NOTHING there — its `false` means "unable to check", never
    /// "verified no duplicate". Callers consult this instead of presenting
    /// the absent duplicate warning as a verification.
    var duplicateCheckCapability: DuplicateCheckCapability {
        WriteOnlyEventKitPolicy.duplicateCheckCapability(canReadEvents: canReadEvents)
    }

    /// Resolves the writable calendar for a WRITE (2026-11-07 review fix:
    /// the write-only write path). Full access: the identifier lookup is
    /// authoritative. Under WRITE-ONLY the lookup can fail without read
    /// access even though the DEFAULT calendar is authorized and writable —
    /// so the actual `defaultCalendarForNewEvents` is resolved AT WRITE TIME
    /// and accepted ONLY when its identifier matches the user's chosen
    /// calendar (identifier safety: a mismatch is refused, never silently
    /// written to a different calendar). Nil → the caller reports the
    /// calendar as unavailable.
    private func writableCalendar(forWritingWithID calendarID: String, in eventStore: EKEventStore) -> EKCalendar? {
        if let resolved = eventStore.calendar(withIdentifier: calendarID) {
            // Resolved but read-only → refuse (never redirect elsewhere).
            return resolved.allowsContentModifications ? resolved : nil
        }
        guard authorizationStatus == .writeOnly else { return nil }
        guard let fallback = eventStore.defaultCalendarForNewEvents,
              WriteOnlyEventKitPolicy.defaultCalendarFallbackIsSafe(
                defaultCalendarID: fallback.calendarIdentifier,
                chosenCalendarID: calendarID,
                defaultCalendarIsWritable: fallback.allowsContentModifications
              ) else { return nil }
        return fallback
    }

    func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    /// 2026-11-07 owner correction: after the user answers the EventKit
    /// prompt, the long-lived store's source cache can still hold the
    /// pre-grant state (empty calendar list) — the classic stale-store
    /// gap that made "Allow" look disconnected. One explicit source
    /// refresh right after the permission callback, BEFORE the caller
    /// re-reads the phase and enumerates, so the Allow is reflected
    /// immediately. Read-only; no prompt, no write.
    func refreshAfterAuthorizationChange() {
        store.refreshSourcesIfNecessary()
        writeStore.refreshSourcesIfNecessary()
    }

    /// The writable choice under a WRITE-ONLY grant: EventKit cannot
    /// enumerate calendars without read access, but the DEFAULT calendar
    /// for new events remains available and writable. Honest fallback —
    /// an empty array when there is none (the UI shows its own message).
    /// The app never demands full access just to display a connection.
    func defaultWritableChoices() -> [CalendarChoice] {
        guard let calendar = store.defaultCalendarForNewEvents,
              calendar.allowsContentModifications else { return [] }
        return [
            CalendarChoice(
                id: calendar.calendarIdentifier,
                title: calendar.title.isEmpty ? "Untitled calendar" : calendar.title,
                sourceTitle: calendar.source.title
            )
        ]
    }

    /// Every calendar the configured macOS accounts expose as writable.
    /// No provider (Google, Exchange, …) is assumed or invented; EventKit reports them.
    func writableChoices() -> [CalendarChoice] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map {
                CalendarChoice(
                    id: $0.calendarIdentifier,
                    title: $0.title.isEmpty ? "Untitled calendar" : $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                if $0.sourceTitle == $1.sourceTitle { return $0.title < $1.title }
                return $0.sourceTitle < $1.sourceTitle
            }
    }

    func hasExactMatch(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        calendarID: String
    ) -> Bool {
        // WRITE-ONLY honesty (2026-11-07 review): without read access this
        // probe cannot run — `false` here means "unable to check", never a
        // verified "no duplicate" (see `duplicateCheckCapability`).
        guard canReadEvents else { return false }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return false }
        // Narrow window around the draft so we only scan nearby events.
        let windowStart = start.addingTimeInterval(-1)
        let windowEnd = end.addingTimeInterval(1)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: [calendar]
        )
        return store.events(matching: predicate).contains { event in
            EventExactMatch.matches(
                title: title,
                start: start,
                end: end,
                location: location,
                candidateTitle: event.title,
                candidateStart: event.startDate,
                candidateEnd: event.endDate,
                candidateLocation: event.location
            )
        }
    }

    // MARK: - CalendarWriteSink (batch add for multi-draft confirmation)

    /// Attaches ONE explicit alarm `leadMinutes` before the event start
    /// (EventKit: a NEGATIVE `relativeOffset` in seconds = before start).
    /// The reminder attaches to the event — start/end are never shifted.
    /// Out-of-range leads are refused (never silently clamped); the
    /// parser/resolver already clarifies them before this point.
    private func applyReminder(_ reminderLeadMinutes: Int?, to event: EKEvent) throws {
        guard let reminderLeadMinutes else { return }
        guard (0...EventDraftResolver.maximumReminderLeadMinutes).contains(reminderLeadMinutes) else {
            throw CalendarServiceError.saveFailed(
                "The reminder time is too far ahead — reminders can be at most 4 weeks before an event.")
        }
        event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(reminderLeadMinutes * 60)))
    }

    func stageEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) throws -> String {
        guard let calendar = writableCalendar(forWritingWithID: calendarID, in: writeStore) else {
            throw CalendarServiceError.calendarUnavailable
        }
        let event = EKEvent(eventStore: writeStore)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        if let location, !location.isEmpty {
            event.location = location
        }
        // Description (0.3.17): the reviewed user detail persists to the
        // event notes — exactly the value the confirmation card showed.
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            event.notes = notes
        }
        do {
            try applyReminder(reminderLeadMinutes, to: event)
            // Stage without committing; callers commit the batch once (EventKit docs).
            try writeStore.save(event, span: .thisEvent, commit: false)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }
        return event.calendarItemIdentifier
    }

    func commitStaged() throws {
        do { try writeStore.commit() }
        catch { throw CalendarServiceError.saveFailed(error.localizedDescription) }
    }

    func discardStaged() {
        // Best-effort: EventKit gives no universal atomic-rollback guarantee
        // after a failed commit(); the coordinator reconciles via exact-match
        // probes before any retry so nothing is duplicated.
        writeStore.reset()
    }

    @discardableResult
    func addEvent(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?,
        reminderLeadMinutes: Int?,
        calendarID: String
    ) throws -> String {
        guard let calendar = writableCalendar(forWritingWithID: calendarID, in: store) else {
            throw CalendarServiceError.calendarUnavailable
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        if let location, !location.isEmpty {
            event.location = location
        }
        // Description (0.3.17): reviewed user detail → EKEvent.notes.
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            event.notes = notes
        }
        do {
            try applyReminder(reminderLeadMinutes, to: event)
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }
        return event.calendarItemIdentifier
    }

    func schedule(on day: Date, calendarID: String, limit: Int = 50) -> [ScheduleItem] {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        let calendarRef = Calendar.current
        let dayStart = calendarRef.startOfDay(for: day)
        guard let dayEnd = calendarRef.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: [calendar])
        return store.events(matching: predicate)
            .sorted { first, second in
                if first.startDate == second.startDate {
                    return (first.title ?? "") < (second.title ?? "")
                }
                return first.startDate < second.startDate
            }
            .prefix(limit)
            .map {
                ScheduleItem(
                    id: $0.calendarItemIdentifier,
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    location: $0.location,
                    calendarTitle: $0.calendar?.title ?? "",
                    isAllDay: $0.isAllDay
                )
            }
    }

    // MARK: - EventDeleteSink (voice delete; explicit-confirm flow only)

    /// Candidate lookup for the delete flow. Truthful read gating: only
    /// FULL access can enumerate events — a write-only grant cannot run
    /// lookups, so delete is honestly unavailable until the user grants
    /// Full Access (the app never auto-requests here).
    func fetchCandidates(for query: EventLookupQuery) async throws -> [EventCandidate] {
        guard authorizationStatus == .fullAccess else {
            throw DeleteUnavailableError(message: DeleteFlowCopy.eventKitFullAccessNeeded)
        }
        guard let calendar = store.calendar(withIdentifier: query.calendarID) else {
            throw DeleteUnavailableError(message: "That calendar is no longer available. Choose another calendar.")
        }
        let predicate = store.predicateForEvents(
            withStart: query.windowStart,
            end: query.windowEnd,
            calendars: [calendar]
        )
        return store.events(matching: predicate).map { event in
            EventCandidate(
                // eventIdentifier is what `event(withIdentifier:)` resolves;
                // for the non-recurring events this flow allows it equals
                // calendarItemIdentifier.
                id: event.eventIdentifier,
                provider: .eventKit,
                calendarID: query.calendarID,
                calendarTitle: calendar.title,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isRecurring: Self.isRecurringEvent(event),
                location: event.location
            )
        }
    }

    /// Re-fetch one event by its stable EventKit identifier. Nil when the
    /// event no longer exists (deleted/moved elsewhere).
    func refetch(provider: DeleteProvider, calendarID: String, eventID: String) async throws -> EventCandidate? {
        guard provider == .eventKit else { return nil }
        guard let event = store.event(withIdentifier: eventID),
              let calendar = event.calendar,
              calendar.calendarIdentifier == calendarID else {
            return nil
        }
        return EventCandidate(
            id: event.eventIdentifier,
            provider: .eventKit,
            calendarID: calendarID,
            calendarTitle: calendar.title,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isRecurring: Self.isRecurringEvent(event),
            location: event.location
        )
    }

    /// Delete ONE event. Called only by the coordinator after the explicit
    /// user confirm and target revalidation. EventKit `remove` is a
    /// definite synchronous operation — it either commits or throws.
    func delete(candidate: EventCandidate) async throws {
        guard authorizationStatus == .fullAccess else {
            throw DeleteUnavailableError(message: DeleteFlowCopy.eventKitFullAccessNeeded)
        }
        guard let event = store.event(withIdentifier: candidate.id),
              let calendar = event.calendar,
              calendar.calendarIdentifier == candidate.calendarID else {
            throw DeleteUnavailableError(message: DeleteFlowCopy.targetVanished)
        }
        guard calendar.allowsContentModifications else {
            throw DeleteUnavailableError(message: "That calendar is read-only — QuikCal can’t delete from it.")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }
    }

    /// Recurring events are never deletable by QuikCal — the user reviews
    /// them manually. Three signals, any one of which means recurring:
    /// - explicit recurrence rules on the event (master),
    /// - a detached (edited) occurrence of a series,
    /// - `occurrenceDate` set — a non-detached INSTANCE of a series
    ///   (review hardening 2026-11-07: occurrences returned by a
    ///   predicate fetch can carry no rules of their own and are not
    ///   detached, but `occurrenceDate` is non-nil only for instances of
    ///   a recurring series per Apple's EKEvent docs).
    private static func isRecurringEvent(_ event: EKEvent) -> Bool {
        let hasRules = !(event.recurrenceRules?.isEmpty ?? true)
        return hasRules || event.isDetached || event.occurrenceDate != nil
    }
}
