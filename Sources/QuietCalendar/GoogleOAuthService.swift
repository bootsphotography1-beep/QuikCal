import Foundation
import AppKit
import QuietCalendarCore

/// Desktop Google OAuth Authorization Code + PKCE via system browser + loopback.
/// Does not invent a signed-in account when unconfigured. Event writes happen
/// ONLY through the explicit confirmed Add flow — never automatically.
@MainActor
final class GoogleOAuthService: ObservableObject {
    @Published private(set) var phase: GoogleAuthPhase = .unconfigured
    @Published private(set) var directory = GoogleAccountDirectory()
    @Published private(set) var statusMessage: String?
    @Published private(set) var isAuthorizing = false
    /// Sanitized copyable diagnostic (0.3.12): populated ONLY on a token-endpoint
    /// failure. Contains HTTP status, sanitized error code, allowlisted missing
    /// parameter NAME, request field NAMES, app version, running bundle path.
    /// Never parameter values, auth URL, code, verifier, tokens, or secret.
    @Published private(set) var lastDiagnostics: String?

    // Calendar listing / selection state (Settings).
    @Published private(set) var calendars: [GoogleCalendarListEntry] = []
    @Published private(set) var isFetchingCalendars = false
    @Published private(set) var calendarError: String?
    /// Structured, sanitized reason the last calendar-list load failed
    /// (e.g. API disabled vs insufficient permissions vs quota), when the
    /// failure carried structured Google evidence. Derived ONLY from the
    /// parsed error payload — a bare 403 without a recognized reason stays
    /// `.unclassified`; the cause is never guessed. Nil when the last load
    /// succeeded or the error was not an HTTP API failure.
    @Published private(set) var calendarFailure: GoogleCalendarListFailure?
    /// Accounts whose last token operation hit `invalid_grant` (revoked or
    /// expired refresh token). Such accounts are NOT write-ready even though
    /// tokens still exist locally; re-consent clears the flag.
    @Published private(set) var reauthRequiredAccountIDs: Set<String> = []
    /// The account whose calendar list is currently loaded in `calendars`.
    /// Guards against a stale list being matched against a different active
    /// account (e.g. after a disconnect re-pointed the active account).
    @Published private(set) var calendarsLoadedForAccountID: String?
    /// In-memory, account-scoped snapshot of which linked accounts currently
    /// have a usable stored token bundle. Maintained OFF the main thread (the
    /// Keychain read is synchronous and slow when securityd is busy) and
    /// refreshed at auth lifecycle points. Render paths (`destinationReadiness`)
    /// read ONLY this snapshot — never the Keychain, never the network.
    @Published private(set) var storedTokenAccountIDs: Set<String> = []

    private(set) var config: GoogleOAuthClientConfig
    private let defaults: UserDefaults
    /// Internal so the app-layer write sink can build its own token provider
    /// against the same Keychain-backed vault (never exposes token values).
    let tokenVault: GoogleTokenVault
    private var client: GoogleCalendarClient
    private var activePKCE: OAuthPKCE?
    private var loopback: LoopbackHTTPServer?
    /// Thread-safe mirror of the active callback session for the loopback
    /// server's socket thread. The MainActor service (`activePKCE`) remains
    /// the source of truth; this box lets the server classify a request and
    /// render an ACCURATE page (2026-11-07 repair: the old page claimed
    /// success unconditionally) without hopping to the main actor.
    private var callbackSession: ActiveCallbackSession?
    /// In-flight token-presence refresh; cancelled (not awaited) when a newer
    /// refresh supersedes it. Results of a superseded run are discarded.
    private var tokenPresenceRefreshTask: Task<Void, Never>?

    init(
        config: GoogleOAuthClientConfig = .fromEnvironment(),
        defaults: UserDefaults = .standard,
        tokenVault: GoogleTokenVault = KeychainGoogleTokenVault(),
        client: GoogleCalendarClient = GoogleCalendarClient()
    ) {
        self.config = config
        self.defaults = defaults
        self.tokenVault = tokenVault
        self.client = client
        reload()
    }

    func reload() {
        directory = GoogleAccountDirectoryStore.load(from: defaults)
        refreshStoredTokenSnapshot()
        refreshPhase()
    }

    // MARK: - Token-presence snapshot (Keychain OFF the render path)

    /// Refreshes the in-memory token-presence snapshot asynchronously. The
    /// Keychain reads run on a detached background task; the MainActor only
    /// applies the final set. Superseded refreshes are cancelled, and the
    /// applied result is intersected with the CURRENT directory so a
    /// disconnect that races an in-flight refresh can never resurrect a
    /// removed account.
    func refreshStoredTokenSnapshot() {
        let vault = tokenVault
        let accountIDs = directory.accounts.map(\.id)
        tokenPresenceRefreshTask?.cancel()
        tokenPresenceRefreshTask = Task { [weak self] in
            let present = await Task.detached(priority: .utility) {
                GoogleTokenPresenceResolver.accountsWithStoredTokens(vault, accountIDs: accountIDs)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.applyStoredTokenSnapshot(present)
        }
    }

    @MainActor
    private func applyStoredTokenSnapshot(_ present: Set<String>) {
        let known = Set(directory.accounts.map(\.id))
        storedTokenAccountIDs = GoogleTokenPresenceResolver.applying(present, toKnownAccountIDs: known)
    }

    /// Snapshot-based presence check — safe in render paths. Fail-closed:
    /// an account absent from the (freshly refreshed) snapshot reads as
    /// "no stored tokens".
    func hasStoredTokensSnapshot(accountID: String) -> Bool {
        storedTokenAccountIDs.contains(accountID)
    }

    func updateConfig(_ config: GoogleOAuthClientConfig) {
        self.config = config
        refreshPhase()
    }

    /// Adopts a locally imported client secret (Settings → Import Google
    /// configuration… — user-picked Google "Desktop app" JSON, strictly
    /// validated by `GoogleClientSecretJSONImporter`, already persisted in
    /// the dedicated Keychain item by `GoogleClientSecretImportService`).
    ///
    /// Deliberately narrow: it ONLY fills an empty secret. An explicitly
    /// exported `QUIET_CALENDAR_GOOGLE_CLIENT_SECRET` (dev fallback) is
    /// respected and never overridden. It NEVER triggers sign-in, revoke,
    /// token writes, calendar loads, or any other side effect — import and
    /// sign-in are separate, user-initiated steps.
    ///
    /// Refresh propagation: the code exchange, the refresh-grant provider in
    /// `loadCalendars()`, and the `GoogleCalendarWriteSink` wired in
    /// AppDelegate all read `config.clientSecret` AT CALL TIME, so adopting
    /// propagates to every production token call immediately.
    /// Never logs the value.
    func adoptClientSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard config.clientSecret
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        config.clientSecret = trimmed
        refreshPhase()
    }

    var activeAccount: GoogleLinkedAccount? {
        let prefs = AppPreferencesStore(defaults: defaults)
        if let id = prefs.googleActiveAccountID {
            return directory.account(id: id)
        }
        return directory.accounts.first
    }

    var activeTargetCalendarID: String? {
        activeAccount?.targetCalendarID
    }

    // MARK: - Write readiness (drives the UI Add gate)

    /// True when a token bundle exists locally for the account AND its refresh
    /// token is non-empty. A Keychain read failure counts as missing (fail
    /// closed). No network is involved; an expired cached access token still
    /// counts — the token provider refreshes it on use.
    ///
    /// ⚠️ SYNCHRONOUS Keychain read (`SecItemCopyMatching`, can block seconds
    /// when securityd is busy). NEVER call from a SwiftUI body / render path —
    /// use the `storedTokenAccountIDs` snapshot via `hasStoredTokensSnapshot`
    /// or `destinationReadiness` instead. Legitimate callers: one-shot launch
    /// wiring (AppDelegate) and tests.
    func hasStoredTokens(accountID: String) -> Bool {
        guard let bundle = try? tokenVault.loadTokenBundle(accountID: accountID) else {
            return false
        }
        return !bundle.refreshToken.isEmpty
    }

    /// Marks the account as needing re-consent (`invalid_grant` observed on a
    /// real token operation). Called by the write sink when a confirmed Add
    /// hits a rejected refresh, so the UI gate flips closed immediately.
    func markReauthRequired(accountID: String) {
        reauthRequiredAccountIDs.insert(accountID)
    }

    /// Live readiness of the Google write destination, derived from actual
    /// state — never hardcoded. Ready requires: configured client, resolvable
    /// active account, usable (present, non-revoked) tokens, a calendar list
    /// loaded for THAT account, and a selected target that is in that
    /// account's current writable list.
    ///
    /// Render-safe: evaluated during SwiftUI body rendering (Settings status
    /// block and the ViewModel readiness provider). Token presence comes from
    /// the asynchronously maintained `storedTokenAccountIDs` snapshot — this
    /// path performs NO Keychain I/O and NO network. A stale "missing"
    /// snapshot only fails closed (gate stays shut until the refresh lands);
    /// a stale "present" snapshot cannot enable a real write — the write sink
    /// (`GoogleCalendarWriteSink.accessToken`) re-verifies the vault on every
    /// actual write and flags `invalid_grant` itself.
    var destinationReadiness: GoogleDestinationReadiness {
        let account = activeAccount
        let accountID = account?.id
        let reauth = accountID.map { reauthRequiredAccountIDs.contains($0) } ?? false
        return GoogleDestinationReadinessEvaluator.evaluate(
            configConfigured: config.isConfigured,
            accountID: accountID,
            hasStoredTokens: accountID.map { storedTokenAccountIDs.contains($0) } ?? false,
            reauthorizationRequired: reauth,
            isFetchingCalendars: isFetchingCalendars,
            calendarLoadError: calendarError,
            calendarsLoadedForAccountID: calendarsLoadedForAccountID,
            targetCalendarID: account?.targetCalendarID,
            targetCalendarSummary: account?.targetCalendarSummary,
            writableCalendars: calendars
        )
    }

    // MARK: - Sign-in

    func beginSignIn() {
        statusMessage = nil
        lastDiagnostics = nil
        guard config.isConfigured else {
            phase = .unconfigured
            statusMessage = "Google sign-in is not configured. Add a Desktop OAuth client ID — see GOOGLE-CALENDAR-INTEGRATION.md."
            return
        }
        let pkce = OAuthPKCE.make()
        guard let url = OAuthAuthorizationURLBuilder.authorizationURL(
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            pkce: pkce
        ) else {
            statusMessage = "Could not build the Google authorization URL."
            return
        }
        activePKCE = pkce
        isAuthorizing = true
        refreshPhase()

        // Defensive lifecycle cleanup: a previous attempt still waiting on
        // its listener must be retired before this one binds the same port
        // (otherwise the bind fails with a cryptic listener error). Its
        // browser completion is now unambiguously classified as a stale
        // completion instead of silently killing the new session.
        loopback?.stop()
        loopback = nil
        callbackSession?.end()
        callbackSession = nil

        // 2026-11-07 repair: the loopback server now classifies each request
        // BEFORE rendering the page, so the browser states what actually
        // happened (accepted / declined / stale / mismatch) instead of the
        // old unconditional "You can close this window" success copy that
        // produced false browser success on failed app-side exchanges.
        // Requests to non-callback paths (e.g. /favicon.ico) no longer
        // consume the single-callback session.
        let expectedPath = OAuthCallbackClassifier.expectedCallbackPath(redirectURI: config.redirectURI)
        let session = ActiveCallbackSession(expectedPath: expectedPath, activeState: pkce.state)
        callbackSession = session
        do {
            let server = try LoopbackHTTPServer(port: config.loopbackPort) { [weak self] path, query in
                let snapshot = session.snapshot()
                let outcome = OAuthCallbackClassifier.classify(
                    query: query,
                    path: path,
                    expectedCallbackPath: snapshot.expectedPath,
                    activeState: snapshot.activeState
                )
                if outcome != .notCallbackPath {
                    session.end()
                    Task { @MainActor [weak self] in
                        self?.handleCallback(query: query, path: path)
                    }
                }
                return outcome
            }
            loopback = server
            try server.start()
        } catch {
            isAuthorizing = false
            activePKCE = nil
            session.end()
            callbackSession = nil
            statusMessage = "Could not start local redirect listener: \(error.localizedDescription)"
            refreshPhase()
            return
        }

        NSWorkspace.shared.open(url)
        // The OAuth browser is an EXTERNAL surface: floating QuikCal
        // surfaces (onboarding) yield their window level so the browser
        // and any Google/consent prompt are never covered. UI
        // coordination only — no grant, no prompt from here.
        NotificationCenter.default.post(
            name: .quikCalExternalSurfaceHandoff,
            object: nil
        )
    }

    func cancelSignIn() {
        loopback?.stop()
        loopback = nil
        activePKCE = nil
        callbackSession?.end()
        callbackSession = nil
        isAuthorizing = false
        refreshPhase()
    }

    // MARK: - Disconnect (revoke + Keychain delete)

    /// Best-effort programmatic revoke at Google, then local token deletion.
    /// Local deletion happens even when revoke fails (network down): the user
    /// asked to disconnect, and stale tokens must not linger in the Keychain.
    func disconnect(accountID: String) {
        if let bundle = try? tokenVault.loadTokenBundle(accountID: accountID) {
            let refresh = bundle.refreshToken
            Task { [client] in
                await client.revoke(token: refresh)
            }
        }
        try? tokenVault.deleteTokens(accountID: accountID)
        directory.remove(id: accountID)
        GoogleAccountDirectoryStore.save(directory, to: defaults)
        let prefs = AppPreferencesStore(defaults: defaults)
        if prefs.googleActiveAccountID == accountID {
            prefs.googleActiveAccountID = directory.accounts.first?.id
        }
        calendars = []
        calendarFailure = nil
        reauthRequiredAccountIDs.remove(accountID)
        if calendarsLoadedForAccountID == accountID {
            calendarsLoadedForAccountID = nil
        }
        // Immediately drop the account from the token-presence snapshot so no
        // render path can treat it as auth-capable; the async refresh confirms.
        storedTokenAccountIDs.remove(accountID)
        refreshStoredTokenSnapshot()
        statusMessage = "Disconnected Google account. Tokens removed from Keychain; revoke was requested at Google (check myaccount.google.com/permissions to confirm)."
        refreshPhase()
    }

    func setTargetCalendar(accountID: String, calendarID: String, summary: String) {
        guard var account = directory.account(id: accountID) else { return }
        account.targetCalendarID = calendarID
        account.targetCalendarSummary = summary
        directory.upsert(account)
        GoogleAccountDirectoryStore.save(directory, to: defaults)
    }

    // MARK: - Calendar listing

    /// Fetches the account's calendar list (writable entries only are offered
    /// as write destinations). Requires a valid access token; refreshes when
    /// expired. `reauthorizationRequired` flips the phase so the UI offers
    /// sign-in again.
    func loadCalendars() {
        guard let account = activeAccount else {
            calendarError = "No linked Google account."
            return
        }
        guard !isFetchingCalendars else { return }
        isFetchingCalendars = true
        calendarError = nil
        calendarFailure = nil
        let accountID = account.id
        // 0.3.12 review fix: the refresh grant must carry the configured
        // client secret too — Google's token endpoint enforcement applies to
        // the refresh GRANT as well, and an omitted secret here would fail the
        // next token refresh (calendar reload / write after token expiry)
        // exactly like the original code exchange did. Never logged.
        let provider = GoogleAccessTokenProvider(
            clientID: config.clientID, clientSecret: config.clientSecret,
            vault: tokenVault, client: client)
        Task { [weak self] in
            guard let self else { return }
            do {
                let access = try await provider.accessToken(accountID: accountID)
                let entries = try await self.client.listCalendars(accessToken: access)
                // Offer writable calendars; primary first, then alphabetical.
                let writable = entries.filter(\.isWritable)
                    .sorted { lhs, rhs in
                        if lhs.primary != rhs.primary { return lhs.primary }
                        return lhs.summary.localizedCaseInsensitiveCompare(rhs.summary) == .orderedAscending
                    }
                self.calendars = writable
                self.calendarsLoadedForAccountID = accountID
                self.reauthRequiredAccountIDs.remove(accountID)
                self.isFetchingCalendars = false
                self.calendarFailure = nil
            } catch GoogleAccessTokenProvider.ProviderError.reauthorizationRequired {
                self.isFetchingCalendars = false
                self.calendarError = nil
                self.calendarFailure = nil
                self.reauthRequiredAccountIDs.insert(accountID)
                self.statusMessage = "Google access was revoked or expired — sign in again."
                self.refreshPhase()
            } catch let error as GoogleAPIError {
                self.isFetchingCalendars = false
                // Evidence-based, sanitized classification (e.g. API
                // disabled vs insufficient permissions vs quota) whenever
                // Google returned a structured reason; unclassified
                // otherwise. No tokens, no account payload, no raw body.
                if case .http = error {
                    let category = error.failureCategory
                    let failure = GoogleCalendarListFailure(category: category, message: category.userFacingMessage)
                    self.calendarFailure = failure
                    self.calendarError = failure.message
                } else {
                    self.calendarFailure = nil
                    self.calendarError = error.localizedDescription
                }
            } catch {
                self.isFetchingCalendars = false
                self.calendarFailure = nil
                self.calendarError = error.localizedDescription
            }
        }
    }

    // MARK: - Callback / exchange

    /// App-side callback handling. Re-classifies against the MainActor
    /// source of truth (`activePKCE`) rather than trusting the server's
    /// snapshot: state can change between the socket thread's page render
    /// and this MainActor task (e.g. the user pressed Sign in again), and
    /// exchanging a superseded code with a NEW verifier would fail at
    /// Google anyway. The browser page already told the user the truth for
    /// the snapshot it saw; this governs the actual app-side flow.
    private func handleCallback(query: [String: String], path: String?) {
        defer {
            callbackSession?.end()
            callbackSession = nil
            loopback?.stop()
            loopback = nil
            isAuthorizing = false
        }
        let outcome = OAuthCallbackClassifier.classify(
            query: query,
            path: path,
            expectedCallbackPath: OAuthCallbackClassifier.expectedCallbackPath(redirectURI: config.redirectURI),
            activeState: activePKCE?.state
        )
        switch outcome {
        case .notCallbackPath:
            // Never dispatched by the server for non-callback paths;
            // defensive: nothing is consumed app-side either.
            return
        case .noActiveSession:
            // Stale completion: the browser's success was real at Google,
            // but this app was no longer waiting for it (relaunched,
            // cancelled, or superseded by a newer sign-in). Actionable and
            // honest — no tokens were saved.
            activePKCE = nil
            statusMessage = "That sign-in window was no longer active — QuikCal wasn't waiting for it. Press Sign in with Google to start again."
            refreshPhase()
            return
        case .stateMismatch:
            activePKCE = nil
            statusMessage = "Security check failed — the browser response didn't match the sign-in started here (a second sign-in window can cause this). Press Sign in with Google to start again."
            refreshPhase()
            return
        case .authorizationDenied(let code):
            // Only the sanitized RFC 6749 code shape is echoed.
            activePKCE = nil
            statusMessage = code == nil
                ? "Google authorization failed."
                : "Google authorization failed (\(code!))."
            refreshPhase()
            return
        case .missingCode:
            activePKCE = nil
            statusMessage = "Google's response was missing the authorization code. Press Sign in with Google to start again."
            refreshPhase()
            return
        case .accepted:
            break
        }
        guard let pkce = activePKCE else {
            activePKCE = nil
            statusMessage = "Sign-in session expired — press Sign in with Google to start again."
            refreshPhase()
            return
        }
        activePKCE = nil

        // The classifier guarantees a non-empty code for `.accepted`; the
        // explicit re-bind keeps the guard (and future classifier edits)
        // from silently exchanging junk.
        guard let code = query["code"], !code.isEmpty else {
            statusMessage = "Google's response was missing the authorization code. Press Sign in with Google to start again."
            refreshPhase()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await self.exchangeCode(code, pkce: pkce)
                let accountID = tokens.accountID ?? UUID().uuidString
                let email = tokens.email ?? "linked-account"
                try self.tokenVault.saveTokenBundle(
                    GoogleTokenBundle(
                        refreshToken: tokens.refreshToken,
                        accessToken: tokens.accessToken,
                        accessTokenExpiresAt: tokens.accessTokenExpiresAt
                    ),
                    accountID: accountID
                )
                let account = GoogleLinkedAccount(id: accountID, email: email)
                self.directory.upsert(account)
                GoogleAccountDirectoryStore.save(self.directory, to: self.defaults)
                AppPreferencesStore(defaults: self.defaults).googleActiveAccountID = accountID
                // Fresh consent: any prior invalid_grant flag for this
                // account is cleared (loadCalendars re-verifies on success).
                self.reauthRequiredAccountIDs.remove(accountID)
                // Refresh the token-presence snapshot now that the new tokens
                // are in the vault and the account is in the directory.
                self.refreshStoredTokenSnapshot()
                self.lastDiagnostics = nil
                self.statusMessage = "Signed in as \(email). Now choose a target calendar below — every Add still needs your explicit confirmation."
                self.loadCalendars()
                self.refreshPhase()
            } catch let failure as OAuthServiceError {
                self.statusMessage = failure.errorDescription
                self.refreshPhase()
            } catch {
                self.statusMessage = "Token exchange failed: \(error.localizedDescription)"
                self.refreshPhase()
            }
        }
    }

    private struct TokenResult {
        var refreshToken: String
        var accessToken: String?
        var accessTokenExpiresAt: Date?
        var email: String?
        var accountID: String?
    }

    private func exchangeCode(_ code: String, pkce: OAuthPKCE) async throws -> TokenResult {
        var request = URLRequest(url: OAuthAuthorizationURLBuilder.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthTokenExchangeRequest.formBody(
            code: code,
            redirectURI: config.redirectURI,
            clientID: config.clientID,
            codeVerifier: pkce.codeVerifier,
            clientSecret: config.clientSecret
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthServiceError.unexpectedResponse
        }
        // Non-2xx: classify Google's RFC 6749 `error` code (sanitized,
        // allowlisted mappings) instead of discarding the body — the 2026-11-06
        // bare "returned an error" message was unactionable. Only the short
        // error code and allowlisted structural parameter NAMES are surfaced;
        // `error_description`, tokens, and URLs never reach the UI or logs.
        guard (200..<300).contains(http.statusCode) else {
            let failure = GoogleTokenEndpointFailure.classify(status: http.statusCode, body: data)
            lastDiagnostics = GoogleOAuthDiagnostics.copyableSummary(
                status: failure.status,
                googleError: failure.googleError,
                missingParameter: failure.missingParameter,
                usesClientSecret: !config.clientSecret
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown",
                bundlePath: Bundle.main.bundlePath
            )
            throw OAuthServiceError.tokenEndpointFailed(failure)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthServiceError.unexpectedResponse
        }
        guard let refresh = json["refresh_token"] as? String, !refresh.isEmpty else {
            // Some re-consents omit refresh_token; treat as incomplete for multi-account store.
            // (Official docs: refresh tokens are always returned for installed
            // applications, so this indicates an unexpected grant shape.)
            throw OAuthServiceError.missingRefreshToken
        }
        let grant = (try? GoogleTokenResponseParser.parseAccessGrant(data, now: client.now()))
        let idToken = json["id_token"] as? String
        let identity = idToken.map { GoogleTokenResponseParser.parseIDToken($0) }
        return TokenResult(
            refreshToken: refresh,
            accessToken: grant?.accessToken,
            accessTokenExpiresAt: grant?.expiresAt,
            email: identity?.email,
            accountID: identity?.sub
        )
    }

    private func refreshPhase() {
        phase = GoogleAuthStateResolver.phase(
            config: config,
            hasLinkedAccounts: !directory.accounts.isEmpty,
            isAuthorizing: isAuthorizing,
            lastError: nil
        )
        if !config.isConfigured {
            phase = .unconfigured
        }
    }

    enum OAuthServiceError: LocalizedError {
        /// Non-2xx from the token endpoint, classified into a sanitized,
        /// actionable message (no tokens, no raw body, no URLs).
        case tokenEndpointFailed(GoogleTokenEndpointFailure)
        case missingRefreshToken
        case unexpectedResponse
        var errorDescription: String? {
            switch self {
            case .tokenEndpointFailed(let failure): return failure.userFacingMessage
            case .missingRefreshToken: return "No refresh token returned. Re-consent with prompt=consent."
            case .unexpectedResponse: return "Unexpected response from the Google token endpoint."
            }
        }
    }
}

// MARK: - Thread-safe callback session mirror

/// Mirror of the active callback session for the loopback server's socket
/// thread. The MainActor service stays the source of truth; this box only
/// carries the two values the socket thread needs to classify a request and
/// render an accurate page. `end()` clears both so any request arriving
/// after the session is consumed classifies as a stale completion instead
/// of being silently accepted.
private final class ActiveCallbackSession: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedPath: String?
    private var activeState: String?

    init(expectedPath: String?, activeState: String) {
        self.expectedPath = expectedPath
        self.activeState = activeState
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        expectedPath = nil
        activeState = nil
    }

    func snapshot() -> (expectedPath: String?, activeState: String?) {
        lock.lock(); defer { lock.unlock() }
        return (expectedPath, activeState)
    }
}

// MARK: - Minimal loopback server

/// 2026-11-07 connection repair:
/// - The response page is rendered from the CLASSIFIED outcome, not an
///   unconditional "you can close this window" success copy — the browser
///   must never report success for a callback the app did not accept.
/// - Only requests to the configured callback path consume the session;
///   other paths (e.g. /favicon.ico) get a neutral page and the listener
///   keeps waiting, so a stray request can no longer silently abort a
///   sign-in in progress.
/// - The request is read until end-of-headers (bounded, non-blocking after
///   the first segment): a single read() can return a truncated request
///   line when the callback request spans TCP segments.
/// - The listener self-stops after a callback-path request; `stop()` is
///   lock-protected because it is now called from both the socket queue
///   and the main actor.
private final class LoopbackHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let onRequest: @Sendable (_ path: String?, _ query: [String: String]) -> OAuthCallbackOutcome
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1

    init(
        port: Int,
        onRequest: @escaping @Sendable (_ path: String?, _ query: [String: String]) -> OAuthCallbackOutcome
    ) throws {
        self.port = UInt16(port)
        self.onRequest = onRequest
    }

    func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard listen(fd, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            self?.acceptOnce()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func acceptOnce() {
        stateLock.lock()
        let listenFD = fd
        stateLock.unlock()
        guard listenFD >= 0 else { return }
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        let request = Self.readRequest(client: client)
        let (path, query) = Self.parseCallbackRequest(fromHTTPRequest: request)
        let outcome = onRequest(path, query)
        let body = OAuthCallbackPageRenderer.htmlBody(outcome: outcome, appName: AppBranding.displayName)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { ptr in write(client, ptr, strlen(ptr)) }
        // A request to the actual callback path ends the browser flow: the
        // listener stops so no second callback can be accepted. Requests
        // to OTHER paths leave the session alive and the listener running.
        if outcome != .notCallbackPath {
            stop()
        }
    }

    /// Reads the request until end-of-headers. The first read is blocking
    /// (the peer sends immediately after connect); continuation reads are
    /// non-blocking and bounded so a slow/malicious peer cannot pin a
    /// thread. Returns "" when nothing usable arrived.
    static func readRequest(client: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var data = [UInt8]()
        let first = read(client, &buffer, buffer.count)
        guard first > 0 else { return "" }
        data.append(contentsOf: buffer.prefix(first))
        while data.count < 16_384 {
            if String(bytes: data, encoding: .utf8)?.contains("\r\n\r\n") == true { break }
            let more = recv(client, &buffer, buffer.count, MSG_DONTWAIT)
            if more <= 0 { break }
            data.append(contentsOf: buffer.prefix(more))
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Splits the request line into the request path and the decoded query
    /// parameters. Returns (nil, [:]) for unusable requests.
    static func parseCallbackRequest(fromHTTPRequest request: String) -> (path: String?, query: [String: String]) {
        let first = request.split(separator: "\r\n", maxSplits: 1).first ?? Substring()
        let parts = first.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])") else { return (nil, [:]) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var dict: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            dict[item.name] = item.value ?? ""
        }
        return (components?.path, dict)
    }
}
