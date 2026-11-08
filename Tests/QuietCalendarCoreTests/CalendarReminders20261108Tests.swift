import Testing
import Foundation
@testable import QuietCalendarCore

// Focused regression tests for the 2026-11-08 calendar-reminders work:
// voice reminder lead times (built-in parser + phrase path), provider
// reminder mapping (EventKit/Google), honest saved-event receipts, and the
// evidence-based Google calendar-list failure classification (403).
//
// NOT RUN by this task's worker (owner: fewer checks — one release build
// will run them at integration). Static source only.

// MARK: - Local mocks

@MainActor
private final class ReminderRecordingEventKitSink: CalendarEventSink {
    struct Recorded: Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var reminderLeadMinutes: Int?
        var calendarID: String
    }
    var recorded: [Recorded] = []

    func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) -> Bool {
        false
    }

    func addEvent(title: String, start: Date, end: Date, location: String?, notes: String?,
                  reminderLeadMinutes: Int?, calendarID: String) throws -> String {
        recorded.append(Recorded(title: title, start: start, end: end, location: location,
                                 reminderLeadMinutes: reminderLeadMinutes, calendarID: calendarID))
        return "ek-\(recorded.count)"
    }
}

@MainActor
private final class ReminderRecordingGoogleSink: GoogleWriteCoordinator.Sink {
    var lastReminderLeadMinutes: Int?
    var insertCount = 0

    func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) async throws -> Bool {
        false
    }

    func insertEvent(title: String, start: Date, end: Date, location: String?, notes: String?,
                     reminderLeadMinutes: Int?, calendarID: String) async throws -> GoogleInsertedEvent {
        insertCount += 1
        lastReminderLeadMinutes = reminderLeadMinutes
        return GoogleInsertedEvent(id: "g-\(insertCount)", htmlLink: "https://www.google.com/calendar/event?eid=g-\(insertCount)")
    }
}

// MARK: - Reminder parsing (built-in parser)

@Suite
struct ReminderParsingTests {
    private func parse(_ text: String) -> ParseResult {
        EventParser().parse(text, now: Date(timeIntervalSince1970: 1_793_880_000))
    }

    private func draft(_ text: String) -> EventDraft? {
        if case .event(let d) = parse(text) { return d }
        return nil
    }

    private func clarification(_ text: String) -> String? {
        if case .needsClarification(let message) = parse(text) { return message }
        return nil
    }

    @Test func numericMinutesAndHoursBefore() {
        #expect(draft("dentist tomorrow 3pm remind me 15 minutes before")?.reminderLeadMinutes == 15)
        #expect(draft("dentist tomorrow 3pm remind me 2 hours before")?.reminderLeadMinutes == 120)
        #expect(draft("call bob tomorrow 9am remind me 90 mins before")?.reminderLeadMinutes == 90)
    }

    @Test func hoursConvertToMinutesOnce() {
        #expect(draft("dentist tomorrow 3pm remind me 1 hour 30 minutes before")?.reminderLeadMinutes == 90)
        #expect(draft("dentist tomorrow 3pm remind me 1.5 hours before")?.reminderLeadMinutes == 90)
    }

    @Test func spokenNumbers() {
        #expect(draft("dentist tomorrow 3pm remind me five minutes before")?.reminderLeadMinutes == 5)
        #expect(draft("dentist tomorrow 3pm remind me fifteen minutes before")?.reminderLeadMinutes == 15)
        #expect(draft("dentist tomorrow 3pm remind me forty five minutes before")?.reminderLeadMinutes == 45)
        #expect(draft("dentist tomorrow 3pm remind me twenty minutes before")?.reminderLeadMinutes == 20)
        #expect(draft("dentist tomorrow 3pm remind me three hours before")?.reminderLeadMinutes == 180)
    }

    @Test func idiomaticLeadTimes() {
        #expect(draft("dentist tomorrow 3pm remind me an hour before")?.reminderLeadMinutes == 60)
        #expect(draft("dentist tomorrow 3pm remind me half an hour before")?.reminderLeadMinutes == 30)
        #expect(draft("dentist tomorrow 3pm remind me an hour and a half before")?.reminderLeadMinutes == 90)
        #expect(draft("dentist tomorrow 3pm remind me one and a half hours before")?.reminderLeadMinutes == 90)
        #expect(draft("dentist tomorrow 3pm remind me a minute before")?.reminderLeadMinutes == 1)
    }

    @Test func reminderPhraseIsRemovedFromTitle() {
        // 0.3.17: the title is the concise tidied event name ("Dentist"),
        // never the raw utterance; the reminder phrase never pollutes it.
        #expect(draft("dentist tomorrow 3pm remind me 15 minutes before")?.title == "Dentist")
        #expect(draft("standup friday 9am with a reminder 10 minutes before")?.reminderLeadMinutes == 10)
    }

    @Test func reminderDoesNotShiftStartOrEatDuration() {
        // "15 minutes" must NOT become the event duration.
        let d = draft("dentist tomorrow 3pm for 45 minutes remind me 15 minutes before")
        #expect(d?.reminderLeadMinutes == 15)
        #expect(d != nil && Int(d!.end.timeIntervalSince(d!.start)) == 45 * 60)
        // Same event without the reminder parses to the same start/end.
        let plain = draft("dentist tomorrow 3pm for 45 minutes")
        #expect(d?.start == plain?.start)
        #expect(d?.end == plain?.end)
    }

    @Test func noReminderLeavesFieldNil() {
        #expect(draft("dentist tomorrow 3pm")?.reminderLeadMinutes == nil)
        #expect(draft("remind me to call bob tomorrow 3pm")?.reminderLeadMinutes == nil)
    }

    @Test func unsupportedDayUnitAsks() {
        let message = clarification("dentist tomorrow 3pm remind me 2 days before")
        #expect(message?.contains("minutes or hours") == true)
    }

    @Test func negativeReminderAsks() {
        let message = clarification("dentist tomorrow 3pm remind me -15 minutes before")
        #expect(message?.contains("negative") == true)
    }

    @Test func bareNumberWithoutUnitAsks() {
        let message = clarification("dentist tomorrow 3pm remind me 15 before")
        #expect(message?.contains("unit") == true)
    }

    @Test func overflowBeyondProviderLimitAsks() {
        let message = clarification("dentist tomorrow 3pm remind me 50000 minutes before")
        #expect(message?.contains("too far ahead") == true)
    }

    @Test func conflictingRemindersAskInsteadOfPicking() {
        let message = clarification("dentist tomorrow 3pm remind me 15 minutes before remind me 30 minutes before")
        #expect(message?.contains("more than one reminder") == true)
    }

    @Test func repeatedEqualReminderIsFine() {
        #expect(draft("dentist tomorrow 3pm remind me 15 minutes before remind me 15 minutes before")?.reminderLeadMinutes == 15)
    }

    @Test func maximumBoundaryIsAccepted() {
        // 4 weeks = 40,320 minutes — the documented Google upper bound.
        #expect(draft("dentist tomorrow 3pm remind me 40320 minutes before")?.reminderLeadMinutes == 40_320)
    }

    @Test func reminderPhraseParsingWithoutCue() {
        // Model path: the isolated reminder phrase carries no "remind me" cue.
        #expect(EventParser().parseReminderPhrase("15 minutes before").leadMinutes == 15)
        #expect(EventParser().parseReminderPhrase("remind me an hour before").leadMinutes == 60)
        #expect(EventParser().parseReminderPhrase("2 days before").leadMinutes == nil)
    }

    @Test func resolverRejectsOutOfRangeReminderFromIntent() {
        // Defense in depth: the resolver clarifies even if a caller bypasses the parser.
        let intent = EventIntent(
            title: "T", date: nil,
            time: DateComponents(hour: 15, minute: 0),
            durationSeconds: nil, location: nil,
            reminderLeadMinutes: 99_999)
        let result = EventDraftResolver(calendar: Calendar(identifier: .gregorian))
            .resolve(intent, now: Date(timeIntervalSince1970: 1_793_880_000))
        if case .needsClarification(let message) = result {
            #expect(message.contains("too far ahead"))
        } else {
            Issue.record("expected clarification for out-of-range reminder")
        }
    }
}

// MARK: - Phrase path (model pipeline) reminder resolution

@Suite
struct ReminderPhrasePathTests {
    private let now = Date(timeIntervalSince1970: 1_793_880_000)

    private func resolve(_ phrases: EventPhrases) -> Resolution {
        DateResolver(calendar: Calendar(identifier: .gregorian)).resolve(
            phrases,
            transcript: "dentist tomorrow 3pm remind me 15 minutes before",
            now: now,
            provenance: DraftProvenance(source: .builtInParser, transcript: "t",
                                         referenceNowISO: "2026-11-01T00:00:00Z", timeZoneID: "UTC"))
    }

    @Test func reminderPhraseResolvesOntoDraft() {
        let phrases = EventPhrases(title: "Dentist", datePhrase: "tomorrow",
                                   timePhrase: "3pm", durationPhrase: nil,
                                   location: nil, reminderPhrase: "15 minutes before")
        guard case .resolved(let draft) = resolve(phrases) else {
            Issue.record("expected resolved draft"); return
        }
        #expect(draft.reminderLeadMinutes == 15)
    }

    @Test func unusableReminderPhraseIsLabelledNeverSilent() {
        let phrases = EventPhrases(title: "Dentist", datePhrase: "tomorrow",
                                   timePhrase: "3pm", durationPhrase: nil,
                                   location: nil, reminderPhrase: "2 days before")
        guard case .resolved(let draft) = resolve(phrases) else {
            Issue.record("expected resolved draft"); return
        }
        #expect(draft.reminderLeadMinutes == nil)
        #expect(draft.defaultsApplied.contains { $0.contains("no reminder will be set") })
    }

    @Test func composerCarriesReminderIntoConfirmationDraft() {
        let phrases = EventPhrases(title: "Dentist", datePhrase: "tomorrow",
                                   timePhrase: "3pm", durationPhrase: nil,
                                   location: nil, reminderPhrase: "20 minutes before")
        let validated = [ValidatedPhrases(phrases: phrases, originalPhrases: phrases, issues: [], evidenceNote: nil)]
        let (drafts, _, _) = MultiEventComposer.compose(
            validated: validated, transcript: "dentist tomorrow 3pm remind me 20 minutes before",
            now: now, calendar: Calendar(identifier: .gregorian),
            provenance: DraftProvenance(source: .builtInParser, transcript: "t",
                                        referenceNowISO: "2026-11-01T00:00:00Z", timeZoneID: "UTC"))
        #expect(drafts.first?.reminderLeadMinutes == 20)
    }

    @Test func oldEventPhrasesJSONDecodesWithoutReminderField() {
        // Backward-compatible Codable: payloads encoded before the field existed.
        let json = #"{"title":"Dentist","datePhrase":"tomorrow","timePhrase":"3pm"}"#
        let decoded = try? JSONDecoder().decode(EventPhrases.self, from: Data(json.utf8))
        #expect(decoded?.reminderPhrase == nil)
        #expect(decoded?.title == "Dentist")
    }
}

// MARK: - Provider mapping (Google body / EventKit sink plumbing)

@Suite
struct ReminderProviderMappingTests {
    @Test func googleBodyCarriesExplicitPopupOverrideWithUseDefaultFalse() throws {
        let start = Date(timeIntervalSince1970: 1_800_000)
        let data = try GoogleEventBodyBuilder.body(
            title: "Standup", start: start, end: start.addingTimeInterval(1800),
            location: nil, reminderLeadMinutes: 15)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reminders = try #require(root?["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        let overrides = try #require(reminders["overrides"] as? [[String: Any]])
        #expect(overrides.count == 1)
        #expect(overrides[0]["method"] as? String == "popup")
        #expect(overrides[0]["minutes"] as? Int == 15)
    }

    @Test func googleBodyOmitsRemindersWhenNoneRequested() throws {
        // Provider default reminders must NOT be silently disabled.
        let start = Date(timeIntervalSince1970: 1_800_000)
        let data = try GoogleEventBodyBuilder.body(
            title: "Standup", start: start, end: start.addingTimeInterval(1800), location: nil)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root?["reminders"] == nil)
    }

    @Test func googleBodyRejectsOutOfRangeReminder() {
        let start = Date(timeIntervalSince1970: 1_800_000)
        #expect(throws: GoogleAPIError.invalidEvent) {
            _ = try GoogleEventBodyBuilder.body(
                title: "T", start: start, end: start.addingTimeInterval(60),
                location: nil, reminderLeadMinutes: 99_999)
        }
    }

    @MainActor @Test func confirmedAddPassesReminderToEventKitSink() {
        let sink = ReminderRecordingEventKitSink()
        var writer = ConfirmedEventAdd()
        writer.beginNewDraft()
        let start = Date(timeIntervalSince1970: 1_793_880_000)
        let outcome = writer.submit(
            ConfirmedAddRequest(
                title: "Dentist", start: start, end: start.addingTimeInterval(3600),
                location: nil, calendarID: "cal-1", allowDuplicate: false,
                reminderLeadMinutes: 20),
            sink: sink)
        guard case .created = outcome else {
            Issue.record("expected created"); return
        }
        #expect(sink.recorded.count == 1)
        #expect(sink.recorded[0].reminderLeadMinutes == 20)
    }

    @MainActor @Test func googleCoordinatorPassesReminderToSink() async {
        let sink = ReminderRecordingGoogleSink()
        let draft = ConfirmationDraft(
            title: "Dentist", start: Date(timeIntervalSince1970: 1_800_000),
            end: Date(timeIntervalSince1970: 1_803_600), location: nil,
            source: .builtInParser,
            provenance: DraftProvenance(source: .builtInParser, transcript: "t",
                                        referenceNowISO: "2026-11-01T00:00:00Z", timeZoneID: "UTC"),
            reminderLeadMinutes: 45)
        let result = await GoogleWriteCoordinator.write(
            drafts: [draft], calendarID: "cal-g", calendarSummary: "Work", sink: sink)
        guard case .created = result.outcomes[draft.id] else {
            Issue.record("expected created"); return
        }
        #expect(sink.lastReminderLeadMinutes == 45)
        // Receipt reflects the persisted event only, with Google's own link.
        #expect(result.receipts.count == 1)
        #expect(result.receipts[0].provider == .google)
        #expect(result.receipts[0].eventID == "g-1")
        #expect(result.receipts[0].eventURL == "https://www.google.com/calendar/event?eid=g-1")
        #expect(result.receipts[0].calendarSummary == "Work")
        #expect(result.receipts[0].reminderLeadMinutes == 45)
    }
}

// MARK: - Saved-event receipts (honest outcomes)

@Suite
struct SavedEventReceiptTests {
    private func makeDraft(title: String, reminder: Int? = nil) -> ConfirmationDraft {
        ConfirmationDraft(
            title: title, start: Date(timeIntervalSince1970: 1_800_000),
            end: Date(timeIntervalSince1970: 1_803_600), location: nil,
            source: .builtInParser,
            provenance: DraftProvenance(source: .builtInParser, transcript: "t",
                                        referenceNowISO: "2026-11-01T00:00:00Z", timeZoneID: "UTC"),
            reminderLeadMinutes: reminder)
    }

    @MainActor @Test func eventKitBatchProducesReceiptsOnlyForCreatedEvents() {
        let sink = MockCalendarSink()
        let result = WriteCoordinator().write(
            drafts: [makeDraft(title: "A", reminder: 30), makeDraft(title: "B")],
            calendarID: "cal", calendarSummary: "Work", sink: sink)
        #expect(result.anySaved)
        #expect(result.receipts.count == 2)
        #expect(result.receipts[0].provider == .eventKit)
        #expect(result.receipts[0].eventID == "mock-1")
        #expect(result.receipts[0].calendarSummary == "Work")
        #expect(result.receipts[0].reminderLeadMinutes == 30)
        #expect(result.receipts[1].reminderLeadMinutes == nil)
    }

    @MainActor @Test func stageFailureProducesNoReceiptsAndClaimsNothingSaved() {
        let sink = MockCalendarSink()
        sink.stageFailureFor = ["Bad"]
        let result = WriteCoordinator().write(
            drafts: [makeDraft(title: "Good"), makeDraft(title: "Bad")],
            calendarID: "cal", sink: sink)
        #expect(result.anySaved == false)
        #expect(result.receipts.isEmpty)
    }

    @MainActor @Test func commitUncertainProducesNoReceipts() {
        let sink = MockCalendarSink()
        sink.commitFailure = true
        let result = WriteCoordinator().write(
            drafts: [makeDraft(title: "A")], calendarID: "cal", sink: sink)
        #expect(result.anySaved == false)
        #expect(result.receipts.isEmpty)
    }

    @Test func oldDraftJSONDecodesWithoutReminderField() throws {
        // Backward-compatible Codable for persisted/encoded drafts.
        let start = 1_800_000.0
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Old","start":\(start),"end":\(start + 3600),
        "location":null,"source":"builtInParser","defaultsApplied":[],"issues":[],
        "provenance":{"source":"builtInParser","transcript":"t","referenceNowISO":"2026-11-01T00:00:00Z","timeZoneID":"UTC"}}
        """
        let draft = try JSONDecoder().decode(ConfirmationDraft.self, from: Data(json.utf8))
        #expect(draft.reminderLeadMinutes == nil)
        #expect(draft.title == "Old")
    }
}

// MARK: - Google calendar-list failure classification (evidence-based 403)

@Suite
struct GoogleFailureCategoryTests {
    @Test func accessNotConfiguredMeansAPINotEnabled() {
        let category = GoogleCalendarFailureCategory.classify(status: 403, reason: "accessNotConfigured")
        #expect(category == .apiNotEnabled)
        #expect(category.userFacingMessage.contains("Google Calendar API is turned off"))
    }

    @Test func insufficientPermissionsIsScopeHonest() {
        let category = GoogleCalendarFailureCategory.classify(status: 403, reason: "insufficientPermissions")
        #expect(category == .insufficientPermissions)
        #expect(category.userFacingMessage.contains("Sign in again"))
    }

    @Test func quotaReasonsGroupTogether() {
        #expect(GoogleCalendarFailureCategory.classify(status: 403, reason: "quotaExceeded") == .quotaOrRateLimit)
        #expect(GoogleCalendarFailureCategory.classify(status: 403, reason: "userRateLimitExceeded") == .quotaOrRateLimit)
        #expect(GoogleCalendarFailureCategory.classify(status: 403, reason: "dailyLimitExceeded") == .quotaOrRateLimit)
    }

    @Test func unrecognized403StaysUnclassifiedNeverGuessed() {
        let category = GoogleCalendarFailureCategory.classify(status: 403, reason: nil)
        #expect(category == .unclassified(status: 403))
        #expect(category.userFacingMessage.contains("HTTP 403"))
        #expect(category.userFacingMessage.contains("isn't visible"))
        // A structured reason that is not in the known list is also honest-unknown.
        #expect(GoogleCalendarFailureCategory.classify(status: 403, reason: "mysteryReason") == .unclassified(status: 403))
    }

    @Test func unauthorized401IsAuthenticationRejected() {
        #expect(GoogleCalendarFailureCategory.classify(status: 401, reason: nil) == .authenticationRejected)
    }

    @Test func payloadParserKeepsStructuredCodesOnly() {
        let data = Data(#"{"error":{"code":403,"message":"Project x-secret-detail","errors":[{"reason":"accessNotConfigured","message":"Project x-secret-detail"}],"status":"PERMISSION_DENIED"}}"#.utf8)
        let failure = GoogleErrorPayloadParser.parse(status: 403, data: data)
        #expect(failure == GoogleHTTPFailure(status: 403, reason: "accessNotConfigured", googleStatus: "PERMISSION_DENIED"))
        // The failure type structurally cannot carry the free-text message,
        // so no account/project payload can leak through it.
        #expect(GoogleAPIError.http(status: 403, reason: failure.reason, googleStatus: failure.googleStatus).failureCategory == .apiNotEnabled)
    }

    @Test func nonJSONBodyYieldsNoReason() {
        let failure = GoogleErrorPayloadParser.parse(status: 403, data: Data("gateway noise".utf8))
        #expect(failure == GoogleHTTPFailure(status: 403))
        #expect(GoogleAPIError.http(status: failure.status, reason: failure.reason, googleStatus: failure.googleStatus).failureCategory == .unclassified(status: 403))
    }

    @Test func sanitizedErrorDescriptionIncludesReasonCodeOnly() {
        #expect(GoogleAPIError.http(status: 403, reason: "accessNotConfigured").errorDescription
                == "Google Calendar API error (HTTP 403, accessNotConfigured).")
        #expect(GoogleAPIError.http(status: 500).errorDescription == "Google Calendar API error (HTTP 500).")
    }
}
