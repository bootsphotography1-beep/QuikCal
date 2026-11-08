import Testing
import Foundation
@testable import QuietCalendarCore

// MARK: - Calendar-connection repair (2026-11-06)
//
// Covers the two verified fixes from CALENDAR-CONNECTION-REPAIR.md:
// 1. Sanitized, actionable token-endpoint failure classification (the bare
//    "Google token endpoint returned an error" message is retired; Google's
//    RFC 6749 `error` code is surfaced, `error_description`/tokens/URLs never).
// 2. The token-presence snapshot primitives the service consumes so that
//    `destinationReadiness` (evaluated during SwiftUI body rendering) never
//    performs synchronous Keychain I/O on the main thread.
//
// The service itself lives in the app target (no test target); these tests
// pin the core logic it consumes. Wiring is verified by build + review.

@Suite("Google token-endpoint failure classification")
struct GoogleTokenEndpointFailureTests {

    private func classify(_ status: Int, _ body: String?) -> GoogleTokenEndpointFailure {
        GoogleTokenEndpointFailure.classify(status: status, body: body.map { Data($0.utf8) })
    }

    // MARK: Known (allowlisted) error codes → actionable mapping

    @Test func invalidClientMapsToDesktopClientAdvice() {
        let failure = classify(401, #"{"error":"invalid_client","error_description":"preinstalled client id 123.apps.googleusercontent.com is not authorized"}"#)
        #expect(failure.googleError == "invalid_client")
        #expect(failure.status == 401)
        #expect(failure.userFacingMessage.contains("invalid_client"))
        #expect(failure.userFacingMessage.contains("Desktop"))
        // Never echo error_description (it can embed client IDs / request data).
        #expect(!failure.userFacingMessage.contains("preinstalled"))
        #expect(!failure.userFacingMessage.contains("apps.googleusercontent.com"))
    }

    @Test func invalidGrantMapsToReSignInAdvice() {
        let failure = classify(400, #"{"error":"invalid_grant","error_description":"code was already redeemed"}"#)
        #expect(failure.googleError == "invalid_grant")
        #expect(failure.userFacingMessage.contains("invalid_grant"))
        #expect(failure.userFacingMessage.lowercased().contains("sign in"))
        #expect(!failure.userFacingMessage.contains("redeemed"))
    }

    @Test func redirectURIMismatchMapsToRegistrationAdvice() {
        let failure = classify(400, #"{"error":"redirect_uri_mismatch"}"#)
        #expect(failure.googleError == "redirect_uri_mismatch")
        #expect(failure.userFacingMessage.contains("redirect_uri_mismatch"))
        #expect(failure.userFacingMessage.contains("not registered"))
    }

    @Test func accessDeniedAndInvalidRequestMap() {
        #expect(classify(200, #"{"error":"access_denied"}"#).userFacingMessage.contains("declined"))
        #expect(classify(400, #"{"error":"invalid_request"}"#).userFacingMessage.contains("invalid_request"))
    }

    // MARK: Unknown / hostile codes → safe fallback

    @Test func unknownCodeFallsBackToStatusPlusSanitizedCode() {
        let failure = classify(400, #"{"error":"future_unknown_code"}"#)
        #expect(failure.googleError == "future_unknown_code")
        #expect(failure.userFacingMessage == "Google token endpoint returned HTTP 400 (future_unknown_code).")
    }

    @Test func hostileCodeIsSanitizedNeverEchoedVerbatim() {
        // A malicious/broken body trying to smuggle a URL or script through
        // `error` must not survive verbatim: only letters + underscore survive.
        let failure = classify(400, #"{"error":"javascript:alert(1)//x"}"#)
        #expect(failure.googleError == "javascriptalertx")
        #expect(!failure.userFacingMessage.contains("://"))
        // The only parenthesised content is the wrapper around the sanitized code.
        #expect(failure.userFacingMessage == "Google token endpoint returned HTTP 400 (javascriptalertx).")
    }

    @Test func overlongCodeIsCapped() {
        let long = String(repeating: "a", count: 500)
        let failure = classify(400, "{\"error\":\"\(long)\"}")
        #expect((failure.googleError?.count ?? 0) <= 64)
    }

    @Test func unparsableBodyFallsBackToStatusOnly() {
        let failure = classify(503, "<html>Gateway timeout</html>")
        #expect(failure.googleError == nil)
        #expect(failure.userFacingMessage == "Google token endpoint returned HTTP 503.")
        #expect(!failure.userFacingMessage.contains("Gateway"))
    }

    @Test func nilBodyFallsBackToStatusOnly() {
        let failure = GoogleTokenEndpointFailure.classify(status: 500, body: nil)
        #expect(failure.googleError == nil)
        #expect(failure.userFacingMessage == "Google token endpoint returned HTTP 500.")
    }

    @Test func errorDescriptionWithTokenLikeContentNeverLeaks() {
        let body = #"{"error":"invalid_grant","error_description":"token ya29.SECRET was revoked","access_token":"ya29.SECRET","refresh_token":"1//SECRET"}"#
        let failure = classify(400, body)
        #expect(!failure.userFacingMessage.contains("ya29"))
        #expect(!failure.userFacingMessage.contains("SECRET"))
        #expect(!failure.userFacingMessage.contains("1//"))
    }

    @Test func nonErrorJSONFieldIsIgnored() {
        // Only a top-level string `error` is read; Google API-style nested
        // error objects must not produce a code from arbitrary subfields.
        let failure = classify(400, #"{"error":{"code":400,"message":"x"}}"#)
        #expect(failure.googleError == nil)
        #expect(failure.userFacingMessage == "Google token endpoint returned HTTP 400.")
    }

    @Test func publicSanitizedCodeFilterMatchesClassifierRules() {
        // The app layer uses this to echo a redirect `error` query param
        // (which is NOT state-validated before display) — same rules as the
        // classifier: letters + underscore only, capped, nil when empty.
        #expect(GoogleTokenEndpointFailure.sanitizedCode("access_denied") == "access_denied")
        #expect(GoogleTokenEndpointFailure.sanitizedCode("bad stuff;drop<script>") == "badstuffdropscript")
        #expect(GoogleTokenEndpointFailure.sanitizedCode(String(repeating: "x", count: 500))?.count == 64)
        #expect(GoogleTokenEndpointFailure.sanitizedCode("!!!") == nil)
    }
}

@Suite("Token-presence snapshot primitives (render-path decoupling)")
struct GoogleTokenPresenceSnapshotTests {

    private func bundle(refresh: String) -> GoogleTokenBundle {
        GoogleTokenBundle(refreshToken: refresh, accessToken: "at", accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func presenceReflectsOnlyAccountsWithNonEmptyRefreshTokens() throws {
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(bundle(refresh: "r1"), accountID: "a1")
        try vault.saveTokenBundle(bundle(refresh: ""), accountID: "a2") // unusable
        let present = GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: ["a1", "a2", "a3"])
        #expect(present == ["a1"])
    }

    /// A throwing vault (Keychain failure) counts as missing — fail closed.
    @Test func vaultFailureFailsClosed() throws {
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(bundle(refresh: "r"), accountID: "a1")
        let failing = ThrowingGoogleTokenVault(error: GoogleTokenVaultTestError.readFailed)
        #expect(GoogleTokenPresenceResolver.accountsWithStoredTokens(failing, accountIDs: ["a1"]).isEmpty)
        // And the healthy vault still reports correctly (isolation check).
        #expect(GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: ["a1"]) == ["a1"])
    }

    /// The resolver is designed to run OFF the main actor: it completes from a
    /// detached task (the service's snapshot refresh path), which is what keeps
    /// synchronous SecItemCopyMatching off SwiftUI body rendering.
    @Test func resolverRunsOffMainActor() async throws {
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(bundle(refresh: "r"), accountID: "a1")
        let present = await Task.detached(priority: .utility) {
            GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: ["a1", "a2"])
        }.value
        #expect(present == ["a1"])
    }

    // MARK: Snapshot application (races)

    @Test func applyingIntersectsWithCurrentDirectory() {
        let known: Set<String> = ["a1", "a2"]
        #expect(GoogleTokenPresenceResolver.applying(["a1", "a2", "a3"], toKnownAccountIDs: known) == ["a1", "a2"])
        #expect(GoogleTokenPresenceResolver.applying(["a9"], toKnownAccountIDs: known).isEmpty)
        #expect(GoogleTokenPresenceResolver.applying([], toKnownAccountIDs: known).isEmpty)
    }

    /// Disconnect race: an in-flight refresh computed presence BEFORE the
    /// disconnect; applying it against the CURRENT directory must not
    /// resurrect the disconnected account.
    @Test func disconnectRaceCannotResurrectRemovedAccount() {
        let staleInFlightResult: Set<String> = ["a1", "a2"]
        let directoryAfterDisconnect: Set<String> = ["a1"] // a2 was disconnected
        let applied = GoogleTokenPresenceResolver.applying(staleInFlightResult, toKnownAccountIDs: directoryAfterDisconnect)
        #expect(applied == ["a1"])
        #expect(!applied.contains("a2"))
    }

    /// Account switch: the snapshot is account-scoped — switching the active
    /// account reads a different key, never a shared/global flag.
    @Test func accountSwitchScopesPresencePerAccount() throws {
        let vault = MutableInMemoryGoogleTokenVault()
        try vault.saveTokenBundle(bundle(refresh: "r1"), accountID: "a1")
        try vault.saveTokenBundle(bundle(refresh: "r2"), accountID: "a2")
        let present = GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: ["a1", "a2"])
        #expect(present.contains("a1") && present.contains("a2"))
        try vault.deleteTokens(accountID: "a2")
        let after = GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: ["a1", "a2"])
        #expect(after == ["a1"])
    }
}

@Suite("EventKit / Google destination independence (policy level)")
struct DestinationIndependenceTests {

    /// The Mac-calendar (EventKit) destination resolves with NO Google state
    /// whatsoever — Mac Calendar is usable independently of Google sign-in.
    @Test func eventKitDestinationNeedsNoGoogleState() {
        let destination = DestinationPolicy.resolve(
            kind: .eventKit,
            eventKitCalendarID: "cal-local",
            googleAccountID: nil,          // no Google account at all
            googleCalendarID: nil
        )
        #expect(destination == .eventKit(calendarID: "cal-local"))
        // And it is writable with confirmation alone — no Google readiness input.
        #expect(DestinationPolicy.canAttemptWrite(destination: destination, confirmationArmed: true))
        #expect(!DestinationPolicy.canAttemptWrite(destination: destination, confirmationArmed: false))
    }

    /// Symmetric: the Google destination requires Google state and ignores
    /// EventKit state — the two paths never bleed into each other.
    @Test func googleDestinationNeedsNoEventKitState() {
        let destination = DestinationPolicy.resolve(
            kind: .google,
            eventKitCalendarID: nil,
            googleAccountID: "acct-1",
            googleCalendarID: "cal-primary"
        )
        #expect(destination == .google(accountID: "acct-1", calendarID: "cal-primary"))
    }

    /// Cross-contamination guard: an EventKit selection cannot satisfy a
    /// Google destination and vice versa.
    @Test func destinationsDoNotCrossSatisfy() {
        #expect(DestinationPolicy.resolve(
            kind: .google, eventKitCalendarID: "cal-local",
            googleAccountID: nil, googleCalendarID: nil) == nil)
        #expect(DestinationPolicy.resolve(
            kind: .eventKit, eventKitCalendarID: nil,
            googleAccountID: "acct-1", googleCalendarID: "cal-primary") == nil)
    }
}

// MARK: - Test plumbing

private enum GoogleTokenVaultTestError: Error { case readFailed }

/// A vault whose reads always fail (simulates a Keychain error) — the snapshot
/// must treat this as "no tokens", never as "tokens present".
private struct ThrowingGoogleTokenVault: GoogleTokenVault {
    let error: Error
    func saveTokenBundle(_ bundle: GoogleTokenBundle, accountID: String) throws {}
    func loadTokenBundle(accountID: String) throws -> GoogleTokenBundle? { throw error }
    func deleteTokens(accountID: String) throws {}
}
