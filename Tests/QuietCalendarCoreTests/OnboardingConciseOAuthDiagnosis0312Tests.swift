import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.12 — concise onboarding + Google invalid_request diagnosis.
///
/// Verified root-cause context (2026-11-06): Google's token endpoint currently
/// REJECTS Desktop-client PKCE exchanges without a client secret —
/// `invalid_request` / "client_secret is missing." — despite the native-app
/// docs labeling `client_secret` "Optional" (Android, iOS, Chrome client types
/// are the documented exemptions). All tests here are FROZEN MOCKED request
/// construction: no network, no credentials, no auth codes, no tokens.
@Suite("Onboarding Concise OAuth Diagnosis 0312")
struct OnboardingConciseOAuthDiagnosis0312Tests {

    // MARK: Token request construction

    @Test func formBodyIncludesConfiguredClientSecret() {
        let body = String(
            decoding: OAuthTokenExchangeRequest.formBody(
                code: "4/0AQSTgQF-code",
                redirectURI: "http://127.0.0.1:53682/oauth/callback",
                clientID: "823797884893-test.apps.googleusercontent.com",
                codeVerifier: "NGB_kkq0T0fF0uq0vE1pU6bQzP3gJ7mXy2wA9cD5eG8hK1",
                clientSecret: "GOCSPX-test-secret"
            ),
        as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("client_secret=GOCSPX-test-secret"))
        #expect(body.contains("code_verifier="))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Foauth%2Fcallback"))
    }

    @Test func formBodyOmitsSecretWhenUnconfigured() {
        let body = String(
            decoding: OAuthTokenExchangeRequest.formBody(
                code: "4/0AQSTgQF-code",
                redirectURI: "http://127.0.0.1:53682/oauth/callback",
                clientID: "823797884893-test.apps.googleusercontent.com",
                codeVerifier: "NGB_kkq0T0fF0uq0vE1pU6bQzP3gJ7mXy2wA9cD5eG8hK1"
            ),
        as: UTF8.self)
        #expect(!body.contains("client_secret"))
    }

    @Test func formBodyEncodesReservedCharacters() {
        // Authorization codes and verifiers can contain RFC 3986 reserved
        // characters; the form encoding must percent-encode them so the
        // request can never be malformed by value content.
        let body = String(
            decoding: OAuthTokenExchangeRequest.formBody(
                code: "4/0A&code=with+reserved%2Fchars",
                redirectURI: "http://127.0.0.1:53682/oauth/callback",
                clientID: "id-with&special=value chars",
                codeVerifier: "verifier~with-reserved._chars~and/symbols=&?"
            ),
        as: UTF8.self)
        // No raw reserved characters may appear inside a value.
        #expect(body.contains("code=4%2F0A%26code%3Dwith%2Breserved%252Fchars"))
        #expect(body.contains("client_id=id-with%26special%3Dvalue%20chars"))
        #expect(body.contains("code_verifier=verifier~with-reserved._chars~and%2Fsymbols%3D%26%3F"))
        // Unreserved characters stay readable (RFC 3986 / Google form rules).
        #expect(body.contains("grant_type=authorization_code"))
    }

    @Test func refreshRequestIncludesConfiguredSecret() {
        let withSecret = String(
            decoding: GoogleRefreshTokenRequest.formBody(
                refreshToken: "1//refresh", clientID: "client-id",
                clientSecret: "GOCSPX-test-secret"),
        as: UTF8.self)
        #expect(withSecret.contains("grant_type=refresh_token"))
        #expect(withSecret.contains("client_secret=GOCSPX-test-secret"))
        let withoutSecret = String(
            decoding: GoogleRefreshTokenRequest.formBody(
                refreshToken: "1//refresh", clientID: "client-id"),
        as: UTF8.self)
        #expect(!withoutSecret.contains("client_secret"))
    }

    // MARK: Allowlisted error_description classification

    private func classify(_ status: Int, _ body: String) -> GoogleTokenEndpointFailure {
        GoogleTokenEndpointFailure.classify(status: status, body: Data(body.utf8))
    }

    @Test func verifiedMissingClientSecretPatternIsAllowlisted() {
        // The exact live shape (2026-11-06): invalid_request + "client_secret is missing."
        let failure = classify(
            400,
            #"{"error":"invalid_request","error_description":"client_secret is missing."}"#
        )
        #expect(failure.googleError == "invalid_request")
        #expect(failure.missingParameter == "client_secret")
        #expect(failure.userFacingMessage.contains("client_secret"))
        #expect(failure.userFacingMessage.contains("requires"))
    }

    @Test func knownPatternVariantsStillAllowlisted() {
        #expect(
            GoogleTokenEndpointFailure.missingParameter(
                fromDescription: "Missing required parameter: client_secret") == "client_secret")
        #expect(
            GoogleTokenEndpointFailure.missingParameter(
                fromDescription: "Parameter client_secret is required for this client.") == "client_secret")
    }

    @Test func arbitraryDescriptionsAreNeverEchoed() {
        // Unknown / hostile description text: no allowlist match, no echo.
        let hostile = #"{"error":"invalid_request","error_description":"visit https://evil.example/?token=SECRETVALUE and leak ya29.TOKEN"}"#
        let failure = classify(400, hostile)
        #expect(failure.googleError == "invalid_request")
        #expect(failure.missingParameter == nil)
        #expect(!failure.userFacingMessage.contains("evil.example"))
        #expect(!failure.userFacingMessage.contains("SECRETVALUE"))
        #expect(!failure.userFacingMessage.contains("ya29"))
        #expect(!failure.userFacingMessage.contains("https"))
    }

    @Test func genericInvalidRequestDoesNotClaimRootCause() {
        let failure = classify(400, #"{"error":"invalid_request"}"#)
        #expect(failure.googleError == "invalid_request")
        #expect(failure.missingParameter == nil)
        // No root-cause claim from code alone; diagnostics are offered.
        #expect(failure.userFacingMessage.contains("invalid_request"))
        #expect(failure.userFacingMessage.contains("Copy diagnostics"))
    }

    // MARK: Sanitized copyable diagnostics

    @Test func diagnosticsContainOnlyAllowlistedFields() {
        let summary = GoogleOAuthDiagnostics.copyableSummary(
            status: 400,
            googleError: "invalid_request",
            missingParameter: "client_secret",
            usesClientSecret: false,
            appVersion: "0.3.12",
            bundlePath: "/Applications/QuikCal.app"
        )
        #expect(summary.contains("http_status: 400"))
        #expect(summary.contains("google_error: invalid_request"))
        #expect(summary.contains("missing_parameter: client_secret"))
        #expect(summary.contains("client_secret_sent: no"))
        #expect(summary.contains("app_version: 0.3.12"))
        #expect(summary.contains("running_path: /Applications/QuikCal.app"))
        // Field NAMES only — never values. CORRECTED 2026-11-07 from live
        // owner diagnostic: `request_fields` lists ONLY actually-emitted
        // fields — `client_secret` appears there when (and only when) it was
        // really sent; previously the hardcoded list always included it,
        // which contradicted `client_secret_sent: no`.
        let fieldsLine = summary.split(separator: "\n")
            .first { $0.hasPrefix("request_fields:") } ?? ""
        for name in ["code", "redirect_uri", "client_id", "code_verifier", "grant_type"] {
            #expect(fieldsLine.contains(name))
        }
        #expect(!fieldsLine.contains("client_secret"))
        // Capability documentation never leaks into the diagnostic output
        // via some other name; only the request_fields line lists names.
        #expect(GoogleOAuthDiagnostics.supportedRequestFieldNames
            .contains("client_secret"))
    }

    @Test func diagnosticsNeverCarrySecretShapedValues() {
        // Even if a caller passes hostile strings in the sanitized slots, the
        // sanitizer strips non code-shape characters.
        let summary = GoogleOAuthDiagnostics.copyableSummary(
            status: 400,
            googleError: "invalid_request GOCSPX-secret-ya29.token",
            missingParameter: "client_secret=https://evil.example",
            usesClientSecret: false,
            appVersion: "0.3.12",
            bundlePath: "/Applications/QuikCal.app"
        )
        #expect(!summary.contains("GOCSPX"))
        #expect(!summary.contains("ya29"))
        #expect(!summary.contains("://"))
        // The hostile "code" is not a known RFC 6749 code → unrecognized.
        #expect(summary.contains("google_error: unrecognized"))
        // The hostile missing-parameter string is not the exact allowlisted
        // NAME → the line is omitted entirely, never echoed.
        #expect(!summary.contains("missing_parameter:"))
        #expect(!summary.contains("evil"))
    }

    // MARK: Config secret resolution (env only, never bundled)

    @Test func secretLoadsFromEnvironmentOnly() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            clientIDKey: "TEST_CLIENT_ID",
            redirectKey: "TEST_REDIRECT",
            clientSecretKey: "TEST_CLIENT_SECRET",
            environment: [
                "TEST_CLIENT_ID": "823797884893-test.apps.googleusercontent.com",
                "TEST_CLIENT_SECRET": "GOCSPX-env-secret"
            ],
            bundleInfo: ["GoogleDesktopOAuthClientID": "823797884893-bundle.apps.googleusercontent.com"]
        )
        #expect(config.clientID == "823797884893-test.apps.googleusercontent.com")
        #expect(config.clientSecret == "GOCSPX-env-secret")

        let noSecret = GoogleOAuthClientConfig.fromEnvironment(
            clientIDKey: "TEST_CLIENT_ID",
            redirectKey: "TEST_REDIRECT",
            clientSecretKey: "TEST_CLIENT_SECRET",
            environment: [:],
            bundleInfo: ["GoogleDesktopOAuthClientID": "823797884893-bundle.apps.googleusercontent.com"]
        )
        #expect(noSecret.clientSecret.isEmpty)
    }

    // MARK: Concise onboarding copy (owner, 2026-11-06)

    @Test func googleSubtitleIsOneShortSentence() {
        #expect(OnboardingGoogleCopy.subtitle == "Sign in to connect your calendar.")
        #expect(!OnboardingGoogleCopy.subtitle.lowercased().contains("scope"))
        #expect(!OnboardingGoogleCopy.subtitle.lowercased().contains("sync"))
    }

    @Test func practiceCopyIsTerse() {
        #expect(HoldToTalkGuideCopy.practiceHoldHint(for: .fn) == "Hold Fn, speak, then release.")
        #expect(HoldToTalkGuideCopy.practiceHoldHint(for: .option) == "Hold Option, speak, then release.")
        #expect(HoldToTalkGuideCopy.practiceNothingSavedNote == "Nothing is saved.")
        #expect(HoldToTalkShortcutKind.fn.shortName == "Fn")
    }

    @Test func accessibilityWhyIsOneShortSentence() {
        let copy = HoldToTalkGuideCopy.accessibilityWhy
        #expect(copy.contains("Accessibility"))
        #expect(!copy.contains("NSEvent"))
        // Names the REAL capability split (2026-11-07 privacy repair):
        // Input Monitoring for the Fn key tap, Accessibility for other keys.
        #expect(copy.contains("Input Monitoring"))
        #expect(copy.contains("Fn"))
        // One sentence: exactly one period.
        #expect(copy.filter { $0 == "." }.count == 1)
    }
}
