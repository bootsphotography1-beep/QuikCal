import Foundation
import CryptoKit

/// Authorization Code + PKCE helpers for desktop Google OAuth.
/// No client secrets are embedded. Values are generated per attempt.
public struct OAuthPKCE: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init(codeVerifier: String, codeChallenge: String, state: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.state = state
    }

    /// RFC 7636 code_verifier: 43–128 unreserved characters.
    public static func make(entropyBytes: Int = 32, stateBytes: Int = 16) -> OAuthPKCE {
        let verifier = randomURLSafe(byteCount: entropyBytes)
        let challenge = Self.challengeS256(for: verifier)
        let state = randomURLSafe(byteCount: stateBytes)
        return OAuthPKCE(codeVerifier: verifier, codeChallenge: challenge, state: state)
    }

    public static func challengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public func validateReturnedState(_ returned: String?) -> Bool {
        guard let returned, !returned.isEmpty else { return false }
        return constantTimeEquals(returned, state)
    }

    public func validateCodeChallenge() -> Bool {
        Self.challengeS256(for: codeVerifier) == codeChallenge
    }
}

public enum OAuthAuthorizationURLBuilder: Sendable {
    public static let googleAuthEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Calendar scopes kept minimal for confirmed event creation + calendar
    /// listing. `calendar.events` covers event insert and event read (probe);
    /// CalendarList listing additionally needs `calendar.readonly`.
    /// Incremental authorization is NOT supported for installed apps, so any
    /// scope change requires full re-consent (prompt=consent is always sent).
    public static let calendarEventsScope = "https://www.googleapis.com/auth/calendar.events"
    public static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    public static let openIDEmailScope = "openid email"

    public static var defaultScopes: [String] {
        [calendarEventsScope, calendarReadonlyScope, openIDEmailScope]
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        pkce: OAuthPKCE,
        scopes: [String] = GoogleAuthorizationScopes.requested,
        promptSelectAccount: Bool = true
    ) -> URL? {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents(url: googleAuthEndpoint, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]
        if promptSelectAccount {
            items.append(URLQueryItem(name: "prompt", value: "select_account consent"))
        }
        components?.queryItems = items
        return components?.url
    }
}

public enum OAuthTokenExchangeRequest: Sendable {
    /// Builds the token-endpoint form body. `clientSecret` is included ONLY
    /// when non-empty. 2026-11-06 live diagnosis: Google's token endpoint
    /// currently REJECTS Desktop-client PKCE exchanges without a client
    /// secret — `invalid_request` / "client_secret is missing." — even though
    /// the native-app docs label `client_secret` "Optional" (Android, iOS,
    /// and Chrome client types are the documented exemptions; Desktop is
    /// enforced in practice). So a configured secret is sent; when none is
    /// configured the request is still built (the sanitized failure
    /// classification names the missing parameter instead of guessing).
    public static func formBody(
        code: String,
        redirectURI: String,
        clientID: String,
        codeVerifier: String,
        clientSecret: String = ""
    ) -> Data {
        var pairs: [(String, String)] = [
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code")
        ]
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            pairs.append(("client_secret", secret))
        }
        let encoded = pairs.map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

private func randomURLSafe(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        // Extremely unlikely; fall back to UUID entropy without claiming CSPRNG.
        return Data(UUID().uuidString.utf8).base64URLEncodedString()
    }
    return Data(bytes).base64URLEncodedString()
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
        diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback callback classification (2026-11-07 connection repair)
//
// PROVEN DEFECT this repairs (read from GoogleOAuthService.swift, not
// hypothesized): the app-layer loopback server answered EVERY request with
// an unconditional "You can close this window and return to the app."
// success page — including requests carrying `error=access_denied`, a
// mismatched `state`, no `code` at all, or arriving when no sign-in
// session was active (stale completion). The browser therefore reported
// success while the app-side flow had failed or been discarded — exactly
// the reported "browser says signed in, app is not signed in" symptom.
// Worse, ANY request on the loopback port (e.g. /favicon.ico) consumed the
// single-callback session, silently aborting a sign-in still in progress.
//
// Classification now runs BEFORE the page is written, the page copy states
// what actually happened, and non-callback paths leave the session alive.
// Security rules preserved: state validation stays constant-time; only
// allowlisted sanitized error-code shapes are ever interpolated; query
// VALUES (code, state, email) never reach a page, message, or log.

/// The verdict for one request hitting the loopback redirect listener.
public enum OAuthCallbackOutcome: Sendable, Equatable {
    /// Valid code + state for the ACTIVE session. This does NOT mean
    /// sign-in completed — the token exchange, Keychain storage, and
    /// calendar load all happen afterwards, in the app.
    case accepted
    /// Google returned an RFC 6749 `error` on the redirect (carries only
    /// the sanitized code shape, never the raw param).
    case authorizationDenied(String?)
    /// No sign-in session is active (expired, cancelled, superseded by a
    /// newer sign-in, or the app relaunched) — a stale completion.
    case noActiveSession
    /// A session is active but the returned `state` does not match.
    case stateMismatch
    /// The redirect carried no authorization code.
    case missingCode
    /// The request path is not the configured OAuth callback path (e.g.
    /// /favicon.ico) — the session stays alive and nothing is consumed.
    case notCallbackPath
}

/// Pure classification shared by the loopback page renderer (socket
/// thread) and the app-side callback handler (main actor), so the browser
/// page and the app verdict can never diverge. All inputs are in-memory;
/// no I/O, no secrets.
public enum OAuthCallbackClassifier: Sendable {

    /// Path component of an http(s) loopback redirect URI, e.g.
    /// "/oauth/callback". nil for non-http schemes (URN/custom) or an
    /// empty path — callers then treat every request path as a callback
    /// candidate so the real callback is never missed (state and code
    /// checks still guard acceptance — fail toward catching the callback,
    /// never toward accepting junk). NOTE: a URN like
    /// "urn:ietf:wg:oauth:2.0:oob" parses its text INTO `path`; filtering
    /// on the http(s) scheme prevents that pseudo-path from ever matching
    /// (and thereby blocking) a real loopback request.
    public static func expectedCallbackPath(redirectURI: String) -> String? {
        guard let components = URLComponents(string: redirectURI),
              components.scheme == "http" || components.scheme == "https",
              !components.path.isEmpty else { return nil }
        return components.path
    }

    /// Classification precedence:
    /// 1. Path mismatch → `.notCallbackPath` (session preserved). Checked
    ///    FIRST so a favicon/probe request can never consume the session,
    ///    whatever query junk it carries.
    /// 2. `error` param → `.authorizationDenied` (sanitized) — more
    ///    informative than a stale/security verdict, and the param is
    ///    sanitized before display either way.
    /// 3. No active session → `.noActiveSession` (stale completion).
    /// 4. `state` missing or not constant-time-equal → `.stateMismatch`.
    /// 5. `code` missing/empty → `.missingCode`.
    /// 6. Otherwise `.accepted`.
    public static func classify(
        query: [String: String],
        path: String?,
        expectedCallbackPath: String?,
        activeState: String?
    ) -> OAuthCallbackOutcome {
        if let expected = expectedCallbackPath, path != expected {
            return .notCallbackPath
        }
        if let error = query["error"], !error.isEmpty {
            return .authorizationDenied(GoogleTokenEndpointFailure.sanitizedCode(error))
        }
        guard let activeState, !activeState.isEmpty else {
            return .noActiveSession
        }
        guard let returned = query["state"], !returned.isEmpty,
              constantTimeEquals(returned, activeState) else {
            return .stateMismatch
        }
        guard let code = query["code"], !code.isEmpty else {
            return .missingCode
        }
        return .accepted
    }
}

/// Renders the loopback browser page for a classified outcome. The page is
/// the ONLY thing the user sees in the browser, so it must state the
/// truth: acceptance means "authorization received, finish in the app" —
/// never "sign-in complete" (exchange, storage, and calendar readiness are
/// app-side and still pending). Structurally incapable of echoing query
/// values: the only interpolated inputs are the allowlisted sanitized
/// error code (letters + underscore, capped) and the app name constant.
public enum OAuthCallbackPageRenderer: Sendable {

    public static func htmlBody(outcome: OAuthCallbackOutcome, appName: String) -> String {
        let heading = "<h1>\(appName)</h1>"
        let content: String
        switch outcome {
        case .accepted:
            content = """
            <p>Google authorization received. Return to \(appName) to finish connecting — sign-in completes in the app, which confirms when your calendar is ready.</p>
            """
        case .authorizationDenied(let code):
            let detail = code.map { " (\($0))" } ?? ""
            content = """
            <p>Google authorization failed\(detail). Return to \(appName) and press Sign in with Google to try again.</p>
            """
        case .noActiveSession:
            content = """
            <p>This sign-in window is no longer active — \(appName) is not waiting for it. Return to \(appName) and press Sign in with Google to start again.</p>
            """
        case .stateMismatch:
            content = """
            <p>This response did not match the sign-in \(appName) started, so it was ignored for safety (a second sign-in window can cause this). Return to \(appName) and press Sign in with Google to start again.</p>
            """
        case .missingCode:
            content = """
            <p>Google's response was missing the authorization code. Return to \(appName) and press Sign in with Google to start again.</p>
            """
        case .notCallbackPath:
            // Neutral page for non-callback paths (favicon, probes). No
            // session information, no success copy.
            content = ""
        }
        return """
        <html><body style="font-family:system-ui;padding:2rem">
        \(heading)
        \(content)
        </body></html>
        """
    }
}
