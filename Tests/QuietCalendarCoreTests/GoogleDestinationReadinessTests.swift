import Testing
import Foundation
@testable import QuietCalendarCore

// MARK: - Google destination readiness (UI Add gate) — fail-closed matrix
//
// The ViewModel's `canAddDraft` for the `.google` destination is derived from
// `GoogleDestinationReadinessEvaluator.evaluate`. These tests pin every blocked
// state and the single ready state, so the gate can never silently reopen or
// stay hardcoded closed again.

private func readyInputs(
    accountID: String? = "acct-1",
    hasStoredTokens: Bool = true,
    reauthorizationRequired: Bool = false,
    isFetchingCalendars: Bool = false,
    calendarLoadError: String? = nil,
    calendarsLoadedForAccountID: String? = "acct-1",
    targetCalendarID: String? = "cal-primary",
    targetCalendarSummary: String? = "Primary",
    writableCalendars: [GoogleCalendarListEntry] = [
        GoogleCalendarListEntry(id: "cal-primary", summary: "Primary", accessRole: "owner", primary: true),
        GoogleCalendarListEntry(id: "cal-work", summary: "Work", accessRole: "writer")
    ]
) -> GoogleDestinationReadiness {
    GoogleDestinationReadinessEvaluator.evaluate(
        configConfigured: true,
        accountID: accountID,
        hasStoredTokens: hasStoredTokens,
        reauthorizationRequired: reauthorizationRequired,
        isFetchingCalendars: isFetchingCalendars,
        calendarLoadError: calendarLoadError,
        calendarsLoadedForAccountID: calendarsLoadedForAccountID,
        targetCalendarID: targetCalendarID,
        targetCalendarSummary: targetCalendarSummary,
        writableCalendars: writableCalendars
    )
}

@Suite("Google destination readiness")
struct GoogleDestinationReadinessTests {

    // MARK: Blocked states

    @Test func notConfiguredIsBlocked() {
        let status = GoogleDestinationReadinessEvaluator.evaluate(
            configConfigured: false, accountID: "acct-1", hasStoredTokens: true,
            reauthorizationRequired: false, isFetchingCalendars: false,
            calendarLoadError: nil, calendarsLoadedForAccountID: "acct-1",
            targetCalendarID: "cal-primary", targetCalendarSummary: "Primary",
            writableCalendars: [])
        guard case .notReady(.notConfigured) = status else {
            Issue.record("Expected .notConfigured, got \(status)")
            return
        }
        #expect(status.failureMessage?.isEmpty == false)
    }

    @Test func signedOutIsBlocked() {
        guard case .notReady(.signedOut) = readyInputs(accountID: nil) else {
            Issue.record("nil account must block"); return
        }
    }

    @Test func staleActiveAccountPointerIsBlocked() {
        // A dangling active-account pointer resolves to no account at all
        // (fail-closed per the independent review, F5) — so accountID is nil.
        guard case .notReady(.signedOut) = readyInputs(accountID: nil) else {
            Issue.record("stale pointer must block"); return
        }
    }

    @Test func reauthorizationRequiredIsBlockedEvenWithTokensAndSelection() {
        // invalid_grant: tokens exist locally but are not usable.
        let status = readyInputs(reauthorizationRequired: true)
        guard case .notReady(.reauthorizationRequired) = status else {
            Issue.record("reauth-required must block"); return
        }
        #expect(status.block?.requiresReauthentication == true)
    }

    @Test func missingStoredTokensIsBlocked() {
        guard case .notReady(.noStoredTokens) = readyInputs(hasStoredTokens: false) else {
            Issue.record("missing tokens must block"); return
        }
    }

    @Test func calendarsLoadingIsBlocked() {
        guard case .notReady(.calendarsLoading) = readyInputs(isFetchingCalendars: true) else {
            Issue.record("loading must block"); return
        }
    }

    @Test func calendarLoadFailureIsBlockedWithMessage() {
        let status = readyInputs(calendarLoadError: "HTTP 503")
        guard case .notReady(.calendarLoadFailed("HTTP 503")) = status else {
            Issue.record("load failure must block"); return
        }
        #expect(status.failureMessage?.contains("HTTP 503") == true)
    }

    @Test func calendarsNeverLoadedIsBlocked() {
        guard case .notReady(.calendarsNotLoaded) = readyInputs(calendarsLoadedForAccountID: nil) else {
            Issue.record("never-loaded list must block"); return
        }
    }

    @Test func calendarListLoadedForDifferentAccountIsBlocked() {
        // The list belongs to acct-2 while acct-1 is active — stale across an
        // account switch; matching against it would be cross-account.
        guard case .notReady(.calendarsNotLoaded) = readyInputs(calendarsLoadedForAccountID: "acct-2") else {
            Issue.record("cross-account list must block"); return
        }
    }

    @Test func noSelectedTargetCalendarIsBlocked() {
        guard case .notReady(.noTargetCalendar) = readyInputs(targetCalendarID: nil) else {
            Issue.record("no selection must block"); return
        }
        guard case .notReady(.noTargetCalendar) = readyInputs(targetCalendarID: "") else {
            Issue.record("empty selection must block"); return
        }
    }

    @Test func staleTargetSelectionIsBlocked() {
        // Selected calendar was deleted (or account changed) — no longer in
        // the account's current writable list.
        guard case .notReady(.targetNotInWritableList) = readyInputs(targetCalendarID: "cal-deleted") else {
            Issue.record("stale selection must block"); return
        }
    }

    @Test func readOnlyTargetIsBlocked() {
        // Reader-role calendars are never in the writable list (the service
        // filters on load); a target that only exists as read-only therefore
        // fails the membership check. Belt-and-braces: the entry model itself.
        #expect(!GoogleCalendarListEntry(id: "r", summary: "R", accessRole: "reader").isWritable)
        #expect(!GoogleCalendarListEntry(id: "r", summary: "R", accessRole: "freeBusyReader").isWritable)
        let status = readyInputs(
            targetCalendarID: "cal-readonly",
            writableCalendars: [GoogleCalendarListEntry(id: "cal-readonly", summary: "R", accessRole: "reader")]
        )
        guard case .notReady(.targetNotInWritableList) = status else {
            Issue.record("read-only target must block"); return
        }
    }

    // MARK: Ready state

    @Test func signedInWritableSelectedTargetIsReady() {
        let status = readyInputs()
        guard case .ready(let accountID, let calendarID, let summary) = status else {
            Issue.record("signed-in + writable target must be ready, got \(status)")
            return
        }
        #expect(accountID == "acct-1")
        #expect(calendarID == "cal-primary")
        #expect(summary == "Primary")
        #expect(status.isReady)
        #expect(status.failureMessage == nil)
    }

    @Test func writerRoleOnSharedCalendarIsReady() {
        // The product offers delegated writable calendars (writer roles), so
        // "owned by the same account" means membership in THAT account's own
        // CalendarList with a writable role — not strictly accessRole=owner.
        let status = readyInputs(targetCalendarID: "cal-work", targetCalendarSummary: "Work")
        #expect(status.isReady)
    }

    // MARK: Priority (fail-closed ordering)

    @Test func notConfiguredWinsOverEverything() {
        let status = GoogleDestinationReadinessEvaluator.evaluate(
            configConfigured: false, accountID: nil, hasStoredTokens: false,
            reauthorizationRequired: true, isFetchingCalendars: true,
            calendarLoadError: "x", calendarsLoadedForAccountID: nil,
            targetCalendarID: nil, targetCalendarSummary: nil, writableCalendars: [])
        guard case .notReady(.notConfigured) = status else {
            Issue.record("notConfigured must win"); return
        }
    }

    @Test func signedOutWinsOverReauth() {
        let status = readyInputs(accountID: nil, reauthorizationRequired: true)
        guard case .notReady(.signedOut) = status else {
            Issue.record("signedOut must win over reauth"); return
        }
    }

    @Test func reauthWinsOverLoadingAndSelection() {
        let status = readyInputs(reauthorizationRequired: true, isFetchingCalendars: true)
        guard case .notReady(.reauthorizationRequired) = status else {
            Issue.record("reauth must win over loading"); return
        }
    }

    // MARK: Readiness → confirmed Add routes through Google exactly once

    /// When the evaluator says ready, the confirmed Add flow the ViewModel
    /// runs is GoogleWriteCoordinator.write against the Google sink: the
    /// probe runs, exactly ONE insert happens, and there is no other
    /// destination involved (single-lane by DestinationPolicy).
    @MainActor
    @Test func readyDestinationWritesThroughGoogleExactlyOnce() async throws {
        final class CountingSink: GoogleWriteCoordinator.Sink {
            private(set) var probeCount = 0
            private(set) var insertCount = 0
            func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) async throws -> Bool {
                probeCount += 1
                return false
            }
            func insertEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) async throws -> GoogleInsertedEvent {
                insertCount += 1
                return GoogleInsertedEvent(id: "google-event-\(insertCount)")
            }
        }

        let status = readyInputs()
        guard case .ready(_, let calendarID, _) = status else {
            Issue.record("precondition: ready"); return
        }
        let sink = CountingSink()
        var draft = ConfirmationDraft(
            title: "Standup",
            start: Date(timeIntervalSince1970: 1_800_000),
            end: Date(timeIntervalSince1970: 1_803_600),
            location: nil,
            source: .appDefaulted,
            provenance: DraftProvenance(
                source: .appDefaulted,
                transcript: "standup",
                referenceNowISO: "1970-01-22T00:00:00Z",
                timeZoneID: "UTC"
            )
        )
        // One confirmed Add → probe once, insert exactly once.
        let result = await GoogleWriteCoordinator.write(drafts: [draft], calendarID: calendarID, sink: sink)
        #expect(sink.insertCount == 1)
        #expect(sink.probeCount == 1)
        guard case .created(let id) = result.outcomes[draft.id] else {
            Issue.record("expected .created"); return
        }
        #expect(id == "google-event-1")

        // A retry of the SAME draft (savedEventID recorded, as the ViewModel
        // does) never writes again — no duplicate, no fallback.
        draft.savedEventID = id
        let retry = await GoogleWriteCoordinator.write(drafts: [draft], calendarID: calendarID, sink: sink)
        guard case .alreadySaved = retry.outcomes[draft.id] else {
            Issue.record("retry must be .alreadySaved"); return
        }
        #expect(sink.insertCount == 1)
    }

    /// Partial-batch retention: draft 1 saves, draft 2 fails — draft 1 keeps
    /// its saved id, draft 2 stays unsaved so a retry re-probes and writes
    /// only the missing one.
    @MainActor
    @Test func partialBatchRetainsSavedDraftsForGoogleRetry() async {
        final class FailingSecondSink: GoogleWriteCoordinator.Sink {
            private(set) var insertCount = 0
            func hasExactMatch(title: String, start: Date, end: Date, location: String?, calendarID: String) async throws -> Bool { false }
            func insertEvent(title: String, start: Date, end: Date, location: String?, notes: String?, reminderLeadMinutes: Int?, calendarID: String) async throws -> GoogleInsertedEvent {
                insertCount += 1
                if insertCount == 2 { throw GoogleAPIError.http(status: 403) }
                return GoogleInsertedEvent(id: "google-event-\(insertCount)")
            }
        }

        func makeDraft(_ title: String) -> ConfirmationDraft {
            ConfirmationDraft(
                title: title,
                start: Date(timeIntervalSince1970: 1_800_000),
                end: Date(timeIntervalSince1970: 1_803_600),
                location: nil,
                source: .appDefaulted,
                provenance: DraftProvenance(
                    source: .appDefaulted,
                    transcript: title,
                    referenceNowISO: "1970-01-22T00:00:00Z",
                    timeZoneID: "UTC"
                )
            )
        }
        let drafts = [makeDraft("One"), makeDraft("Two")]
        let sink = FailingSecondSink()
        let first = await GoogleWriteCoordinator.write(drafts: drafts, calendarID: "cal-primary", sink: sink)
        guard case .created(let savedID) = first.outcomes[drafts[0].id] else {
            Issue.record("draft one must be created"); return
        }
        guard case .failed = first.outcomes[drafts[1].id] else {
            Issue.record("draft two must fail"); return
        }
        #expect(first.anySaved && first.anyFailed)

        // ViewModel retention shape: saved draft records its id, unsaved stays nil.
        var retained = drafts
        retained[0].savedEventID = savedID
        #expect(retained[0].savedEventID != nil)
        #expect(retained[1].savedEventID == nil)

        // Retry: the saved draft is skipped untouched; only the failed one is
        // probed + inserted exactly once more.
        let second = await GoogleWriteCoordinator.write(drafts: retained, calendarID: "cal-primary", sink: sink)
        guard case .alreadySaved = second.outcomes[retained[0].id] else {
            Issue.record("saved draft must be skipped on retry"); return
        }
        guard case .created = second.outcomes[retained[1].id] else {
            Issue.record("failed draft must be written on retry"); return
        }
        #expect(sink.insertCount == 3) // 2 in first pass + 1 retry, never 4
    }
}
