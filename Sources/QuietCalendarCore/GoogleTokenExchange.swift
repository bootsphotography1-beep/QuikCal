import Foundation

// MARK: - Sanitized token-endpoint failure classification
//
// The 2026-11-06 live failure ("Token exchange failed: Google token endpoint
// returned an error") was unactionable because the service discarded Google's
// error body and threw a bare non-2xx error.
//
// CORRECTION (2026-11-06, later the same day): an earlier comment here
// asserted the token exchange does NOT require a client secret for desktop
// clients, citing the native-app docs. CONFIRMED with live evidence
// (2026-11-07, owner's sanitized diagnostic — parameter NAMES only, no
// values): the owner's sign-in reached the token endpoint and was answered
// HTTP 400 `invalid_request` with `missing_parameter: client_secret` and
// `client_secret_sent: no`. The earlier "verified endpoint behavior" claim
// IS trusted today, but only because of this owner-side capture plus the
// multiple independent reports/mechanical reproductions (2025–2026) that
// match it exactly; the docs' "Optional" wording still conflicts on its face
// and remains unadjudicated in this codebase's comments. The secret is
// therefore sent when configured, and failures are classified against an
// allowlist of structural descriptions.
//
// Security rules enforced here:
// - ONLY the short Google error code (e.g. "invalid_client") is surfaced.
// - `error_description` is matched against KNOWN structural patterns only;
//   the raw text is never echoed (it can embed request details/URLs).
// - Token values, full URLs, and raw response bodies never reach the UI.

public struct GoogleTokenEndpointFailure: Sendable, Equatable {
    /// HTTP status returned by the token endpoint (0 when no HTTP response).
    public let status: Int
    /// Short sanitized Google error code, e.g. "invalid_client". nil when the
    /// body was unparseable or contained no usable code.
    public let googleError: String?
    /// Allowlisted structural missing-parameter name (e.g. "client_secret")
    /// detected in Google's `error_description`. Only exact known structural
    /// patterns are recognized — the raw description text is NEVER echoed.
    public let missingParameter: String?
    /// User-facing message: status + mapped advice. Contains no tokens,
    /// secrets, URLs, or raw response body text.
    public let userFacingMessage: String

    public init(
        status: Int,
        googleError: String?,
        userFacingMessage: String,
        missingParameter: String? = nil
    ) {
        self.status = status
        self.googleError = googleError.flatMap(sanitizeErrorCode)
        self.missingParameter = missingParameter.flatMap(sanitizeErrorCode)
        self.userFacingMessage = userFacingMessage
    }

    /// Classifies a failed token-endpoint response. Never throws.
    public static func classify(status: Int, body: Data?) -> GoogleTokenEndpointFailure {
        var code: String?
        var missing: String?
        if let body,
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let raw = root["error"] as? String {
                code = sanitizeErrorCode(raw)
            }
            // Allowlisted structural diagnosis: match KNOWN patterns inside
            // `error_description` and surface only the parameter NAME. The
            // raw description is never stored or echoed — arbitrary text
            // (URLs, IDs, tokens) cannot reach the UI or logs.
            if let description = root["error_description"] as? String {
                missing = Self.missingParameter(fromDescription: description)
            }
        }
        return GoogleEndpointFailureFactory.make(
            status: status, googleError: code, missingParameter: missing)
    }

    /// Allowlist of verified structural `error_description` shapes → the
    /// missing parameter's NAME. Anything unrecognized returns nil.
    /// CONFIRMED live on this machine (2026-11-07 owner diagnostic: HTTP 400
    /// `invalid_request`, `missing_parameter: client_secret`,
    /// `client_secret_sent: no`): a Desktop-client PKCE exchange without the
    /// secret returns `invalid_request` with description
    /// "client_secret is missing."
    public static func missingParameter(fromDescription raw: String) -> String? {
        let lowered = raw.lowercased()
        if lowered.contains("client_secret is missing")
            || lowered.contains("missing required parameter: client_secret")
            || lowered.contains("parameter client_secret is required") {
            return "client_secret"
        }
        return nil
    }
}

/// Keeps only RFC 6749-style error-code characters (letters + underscore),
/// capped in length. Anything else — spaces, URLs, punctuation — is dropped.
func sanitizeErrorCode(_ raw: String) -> String? {
    let capped = String(raw.prefix(64))
    let filtered = String(capped.filter { $0.isLetter || $0 == "_" })
    return filtered.isEmpty ? nil : filtered
}

public extension GoogleTokenEndpointFailure {
    /// Public sanitized-code filter for callers outside this module (e.g.
    /// the app-layer OAuth service echoing a redirect `error` query param).
    /// Same rules as the internal classifier: letters + underscore only,
    /// capped at 64 chars, nil when nothing safe remains.
    static func sanitizedCode(_ raw: String) -> String? {
        sanitizeErrorCode(raw)
    }
}

/// Central message mapping so tests and the service agree on wording.
public enum GoogleEndpointFailureFactory: Sendable {
    public static func make(
        status: Int,
        googleError: String?,
        missingParameter: String? = nil
    ) -> GoogleTokenEndpointFailure {
        let message: String
        switch googleError {
        case "invalid_client":
            message = "Google rejected the OAuth client (invalid_client). The bundled client ID must be a Desktop-type OAuth client — check the Google Cloud Console client type."
        case "invalid_grant":
            message = "The Google authorization code was expired, revoked, or already used (invalid_grant) — press Sign in again."
        case "redirect_uri_mismatch":
            message = "The redirect URI is not registered for this Google OAuth client (redirect_uri_mismatch)."
        case "access_denied":
            message = "Google authorization was declined in the browser."
        case "invalid_request":
            if missingParameter == "client_secret" {
                // CONFIRMED live (2026-11-07 owner diagnostic: HTTP 400
                // invalid_request, missing_parameter client_secret,
                // client_secret_sent no — names only, no values). Actionable
                // and reachable: name the exact Settings action, no raw echo.
                message = "Google requires the OAuth client secret for this client (missing parameter: client_secret). In QuikCal Settings, click Import Google configuration… and pick the JSON you downloaded from Google Cloud Console (Desktop app), then sign in again."
            } else {
                // Root cause is NOT claimed from the code alone — the
                // sanitized diagnostic copy carries the exact fields.
                message = "Google rejected the token request (invalid_request). Use Copy diagnostics for the exact fields."
            }
        case nil:
            message = "Google token endpoint returned HTTP \(status)."
        case .some(let code):
            message = "Google token endpoint returned HTTP \(status) (\(code))."
        }
        return GoogleTokenEndpointFailure(
            status: status,
            googleError: googleError,
            userFacingMessage: message,
            missingParameter: missingParameter
        )
    }
}

// MARK: - Sanitized copyable diagnostics
//
// A private diagnostic the owner can paste when sign-in fails. Contains ONLY:
// HTTP status, the sanitized Google error code, the allowlisted missing
// parameter NAME, the request field NAMES, the app version, and the running
// bundle path. NEVER: parameter values, the authorization URL, the auth code,
// the PKCE verifier/challenge, tokens, the client secret, or account email.

public enum GoogleOAuthDiagnostics: Sendable {
    /// Capability documentation only (kept for reference): every field name
    /// a token request could ever carry. The DIAGNOSTIC output never lists
    /// this as sent fields — see `actualRequestFieldNames`.
    public static let supportedRequestFieldNames: [String] = [
        "code", "redirect_uri", "client_id", "code_verifier",
        "grant_type", "client_secret"
    ]

    /// The ACTUAL field names a token request carries, derived from the
    /// boolean fact `usesClientSecret`. 2026-11-07 live diagnostic showed the
    /// previous hardcoded list reporting `client_secret` inside
    /// `request_fields` while `client_secret_sent: no` — confusing evidence.
    /// The diagnostic must reflect what was actually emitted, never more.
    public static func actualRequestFieldNames(usesClientSecret: Bool) -> [String] {
        var names = ["code", "redirect_uri", "client_id", "code_verifier", "grant_type"]
        if usesClientSecret {
            names.append("client_secret")
        }
        return names
    }

    /// Known RFC 6749 / Google error codes. Anything outside this set is
    /// reported as "unrecognized" — a hostile or unexpected code can never
    /// smuggle token-like text into the diagnostic.
    public static let knownErrorCodes: Set<String> = [
        "invalid_request", "invalid_client", "invalid_grant",
        "unauthorized_client", "access_denied", "unsupported_grant_type",
        "invalid_scope", "server_error", "temporarily_unavailable",
        "redirect_uri_mismatch", "deleted_client"
    ]

    /// Builds the multi-line diagnostic text. All inputs are already
    /// sanitized structures — no secrets or values are accepted, so none can
    /// leak. `usesClientSecret` is a boolean fact, never the value.
    public static func copyableSummary(
        status: Int,
        googleError: String?,
        missingParameter: String?,
        usesClientSecret: Bool,
        appVersion: String,
        bundlePath: String
    ) -> String {
        var lines: [String] = []
        lines.append("QuikCal Google sign-in diagnostic")
        lines.append("app_version: \(appVersion)")
        lines.append("running_path: \(bundlePath)")
        lines.append("http_status: \(status)")
        let safeError = googleError.flatMap { sanitizeErrorCode($0) }
        lines.append("google_error: \(safeError.map { knownErrorCodes.contains($0) ? $0 : "unrecognized" } ?? "none")")
        // Missing-parameter NAME: only the allowlisted value survives.
        if let missingParameter, missingParameter == "client_secret" {
            lines.append("missing_parameter: client_secret")
        }
        lines.append("client_secret_sent: \(usesClientSecret ? "yes" : "no")")
        // ACTUAL emitted field names — `client_secret` appears ONLY when it
        // was really sent (name, never the value).
        lines.append("request_fields: \(actualRequestFieldNames(usesClientSecret: usesClientSecret).joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Token presence (Keychain moved OFF the main thread)
//
// `GoogleOAuthService.destinationReadiness` is evaluated during SwiftUI body
// rendering. It previously called `hasStoredTokens` → synchronous Keychain
// `SecItemCopyMatching` on the main thread on EVERY body evaluation — the
// identified main-thread stall behind the multi-second destination-choice
// lag when securityd is busy. Resolution: the service caches presence
// asynchronously (off-main) and body paths read only the published snapshot.

public enum GoogleTokenPresenceResolver: Sendable {
    /// Returns the subset of `accountIDs` that currently has a usable stored
    /// token bundle (present, non-empty refresh token). A vault read failure
    /// counts as missing — fail closed. Safe to call from any executor
    /// (designed to run OFF the main actor; the service caches its result).
    public static func accountsWithStoredTokens(
        _ vault: GoogleTokenVault,
        accountIDs: [String]
    ) -> Set<String> {
        var present: Set<String> = []
        for id in accountIDs {
            if let bundle = try? vault.loadTokenBundle(accountID: id),
               !bundle.refreshToken.isEmpty {
                present.insert(id)
            }
        }
        return present
    }

    /// Applies a computed presence snapshot against the CURRENTLY known
    /// account ids. Two race guarantees:
    /// - Disconnect race: an in-flight refresh that computed presence BEFORE
    ///   a disconnect can never resurrect the removed account — a disconnected
    ///   account is no longer in the directory, so the intersection drops it.
    /// - Account scoping: the snapshot only ever contains ids of accounts the
    ///   directory currently knows, so per-account lookups stay isolated.
    public static func applying(
        _ present: Set<String>,
        toKnownAccountIDs known: Set<String>
    ) -> Set<String> {
        present.intersection(known)
    }
}
