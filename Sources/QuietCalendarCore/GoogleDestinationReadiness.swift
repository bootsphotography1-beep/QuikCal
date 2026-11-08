import Foundation

/// Why the Google write destination is (or is not) ready for a confirmed Add.
/// Every case is fail-closed: the UI may enable Add only for `.ready`.
public enum GoogleDestinationBlock: Sendable, Equatable {
    /// No Desktop OAuth client ID configured.
    case notConfigured
    /// No active linked account (signed out, disconnected, or a stale
    /// active-account pointer that no longer resolves).
    case signedOut
    /// The last token operation hit `invalid_grant` — the refresh token was
    /// revoked or expired. Stored tokens exist but are not usable.
    case reauthorizationRequired
    /// No token bundle exists for the active account (Keychain read failed
    /// counts as missing — fail closed).
    case noStoredTokens
    /// The calendar list for the active account is being fetched right now.
    case calendarsLoading
    /// The calendar list fetch failed (network/API error).
    case calendarLoadFailed(String)
    /// The calendar list for THIS account has not been loaded in this session.
    case calendarsNotLoaded
    /// Signed in, but no target calendar has been chosen yet.
    case noTargetCalendar
    /// The stored target calendar is not in the active account's current
    /// writable calendar list — stale selection, deleted calendar, demoted to
    /// read-only, or a leftover from a different account.
    case targetNotInWritableList
    /// The readiness provider is not wired (defensive; never expected in the
    /// shipping app).
    case unavailable

    /// User-facing message; also used verbatim by the ViewModel and Settings.
    public var message: String {
        switch self {
        case .notConfigured:
            return "Google is not configured — add a Desktop OAuth client ID and relaunch (see Settings)."
        case .signedOut:
            return "Google is not signed in — sign in and choose a target calendar in Settings."
        case .reauthorizationRequired:
            return "Google access was revoked or expired — sign in again in Settings."
        case .noStoredTokens:
            return "Google sign-in is incomplete — sign in again in Settings."
        case .calendarsLoading:
            return "Loading Google calendars — try again in a moment."
        case .calendarLoadFailed(let message):
            return "Google calendars could not be loaded: \(message) — press Refresh calendars in Settings."
        case .calendarsNotLoaded:
            return "Google calendars have not been loaded yet — press Refresh calendars in Settings."
        case .noTargetCalendar:
            return "Choose a target Google calendar in Settings."
        case .targetNotInWritableList:
            return "The selected Google calendar is no longer available or is read-only — choose it again in Settings."
        case .unavailable:
            return "Google is not ready — sign in and choose a target calendar in Settings."
        }
    }

    /// True when re-signing-in is the fix (drives the Settings affordance).
    public var requiresReauthentication: Bool {
        switch self {
        case .reauthorizationRequired, .noStoredTokens: return true
        default: return false
        }
    }
}

/// The resolved readiness of the Google write destination. `.ready` carries
/// the exact account/calendar the confirmed Add will target.
public enum GoogleDestinationReadiness: Sendable, Equatable {
    case ready(accountID: String, calendarID: String, calendarSummary: String)
    case notReady(GoogleDestinationBlock)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// User-facing reason when not ready; nil when ready.
    public var failureMessage: String? {
        if case .notReady(let block) = self { return block.message }
        return nil
    }

    public var block: GoogleDestinationBlock? {
        if case .notReady(let block) = self { return block }
        return nil
    }
}

/// Pure decision logic for Google Add readiness — no I/O, no network, fully
/// unit-testable. The app layer (GoogleOAuthService) supplies the inputs from
/// live state; the ViewModel consumes the verdict. Every uncertain input
/// fails closed.
///
/// "Owned by the same account" is enforced by requiring the selected calendar
/// to appear in the ACTIVE account's own CalendarList (fetched with that
/// account's token, writable roles only). A calendar left over from another
/// account, a deleted calendar, or one demoted to a read-only role cannot
/// appear in that list and is rejected.
public enum GoogleDestinationReadinessEvaluator: Sendable {
    public static func evaluate(
        configConfigured: Bool,
        accountID: String?,
        hasStoredTokens: Bool,
        reauthorizationRequired: Bool,
        isFetchingCalendars: Bool,
        calendarLoadError: String?,
        calendarsLoadedForAccountID: String?,
        targetCalendarID: String?,
        targetCalendarSummary: String?,
        writableCalendars: [GoogleCalendarListEntry]
    ) -> GoogleDestinationReadiness {
        // 1. Configuration must exist.
        guard configConfigured else { return .notReady(.notConfigured) }
        // 2. An active, resolvable account is required (stale pointer → nil).
        guard let accountID, !accountID.isEmpty else { return .notReady(.signedOut) }
        // 3. A revoked/expired refresh token is NOT usable — re-consent needed.
        //    A merely expired access token is fine: the provider refreshes it.
        if reauthorizationRequired { return .notReady(.reauthorizationRequired) }
        // 4. Tokens must exist locally (Keychain read failure counts as no).
        guard hasStoredTokens else { return .notReady(.noStoredTokens) }
        // 5. Calendar list state must be current for THIS account.
        if isFetchingCalendars { return .notReady(.calendarsLoading) }
        if let calendarLoadError, !calendarLoadError.isEmpty {
            return .notReady(.calendarLoadFailed(calendarLoadError))
        }
        guard calendarsLoadedForAccountID == accountID else {
            return .notReady(.calendarsNotLoaded)
        }
        // 6. A target calendar must be selected.
        guard let targetCalendarID, !targetCalendarID.isEmpty else {
            return .notReady(.noTargetCalendar)
        }
        // 7. The target must be in THIS account's current writable list
        //    (stale selection / deleted / other-account calendars fail here),
        //    AND the matched entry must itself be writable — the evaluator
        //    never trusts the caller to have pre-filtered read-only roles.
        guard let target = writableCalendars.first(where: { $0.id == targetCalendarID }),
              target.isWritable else {
            return .notReady(.targetNotInWritableList)
        }
        return .ready(
            accountID: accountID,
            calendarID: targetCalendarID,
            calendarSummary: targetCalendarSummary ?? targetCalendarID
        )
    }
}
