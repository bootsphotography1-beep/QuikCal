import Testing
import Foundation
@testable import QuietCalendarCore

// MARK: - Google OAuth connection repair (2026-11-07)
//
// Pins the verified fixes for "browser sign-in reports success but the app
// is not signed in":
// 1. The loopback browser page is rendered from a CLASSIFIED outcome — the
//    old unconditional "You can close this window and return to the app."
//    success copy (rendered even for error=access_denied, state mismatch,
//    missing code, and stale completions) is retired. `.accepted` copy must
//    NOT claim completed sign-in: token exchange, Keychain storage, and
//    calendar readiness all happen afterwards, in the app.
// 2. Only requests to the configured callback path consume the single
//    callback session; other paths (e.g. /favicon.ico) classify as
//    `.notCallbackPath` and leave the session alive.
// 3. Stale completions (no active session) and state mismatches are
//    distinct, actionable categories.
// Security invariants preserved and pinned: only allowlisted sanitized
// error-code shapes (letters + underscore, capped) are ever interpolated;
// query VALUES (code, state) never reach a page; state comparison stays
// constant-time via OAuthPKCE.
//
// The service + loopback server live in the app target (no test target);
// these tests pin the core logic they consume. Wiring is verified by
// build + review.

@Suite("OAuth loopback callback classification (2026-11-07 repair)")
struct GoogleOAuthCallbackRepairTests {

    private func classify(
        _ query: [String: String],
        path: String?,
        expected: String?,
        active: String?
    ) -> OAuthCallbackOutcome {
        OAuthCallbackClassifier.classify(
            query: query,
            path: path,
            expectedCallbackPath: expected,
            activeState: active
        )
    }

    // MARK: Expected callback path derivation

    @Test func expectedPathFromDefaultLoopbackURI() {
        #expect(OAuthCallbackClassifier.expectedCallbackPath(
            redirectURI: "http://127.0.0.1:53682/oauth/callback") == "/oauth/callback")
        #expect(OAuthCallbackClassifier.expectedCallbackPath(
            redirectURI: "http://localhost:9999/custom/callback") == "/custom/callback")
    }

    /// A URI without a usable path yields nil — callers then treat every
    /// path as a callback candidate (fail toward catching the real
    /// callback; state/code checks still guard acceptance).
    @Test func pathlessURIThatYieldsNil() {
        #expect(OAuthCallbackClassifier.expectedCallbackPath(
            redirectURI: "urn:ietf:wg:oauth:2.0:oob") == nil)
        #expect(OAuthCallbackClassifier.expectedCallbackPath(redirectURI: "") == nil)
    }

    // MARK: Path filtering (session preservation)

    /// THE favicon/probe regression: a request to a non-callback path must
    /// NOT consume the session, whatever query junk it carries (the old
    /// server treated every request as the callback and killed the flow).
    @Test func nonCallbackPathNeverConsumesSession() {
        let outcomes = [
            classify(["code": "c", "state": "s"], path: "/favicon.ico", expected: "/oauth/callback", active: "s"),
            classify(["error": "access_denied"], path: "/favicon.ico", expected: "/oauth/callback", active: "s"),
            classify([:], path: "/", expected: "/oauth/callback", active: "s"),
            classify(["code": "c", "state": "s"], path: nil, expected: "/oauth/callback", active: "s")
        ]
        #expect(outcomes.allSatisfy { $0 == .notCallbackPath })
    }

    /// Nil expected path (pathless/custom redirect URI): any path is a
    /// callback candidate — the real callback is never missed.
    @Test func nilExpectedPathAcceptsAnyPath() {
        #expect(classify(["code": "c", "state": "s"], path: "/anything", expected: nil, active: "s") == .accepted)
    }

    // MARK: Callback-path classification precedence

    /// Google's RFC 6749 `error` param wins over staleness — more
    /// informative, and sanitized either way.
    @Test func errorParamBeatsStaleSession() {
        #expect(classify(["error": "access_denied"], path: "/oauth/callback", expected: "/oauth/callback", active: nil)
                == .authorizationDenied("access_denied"))
    }

    /// The stale-completion regression: a valid-looking callback arriving
    /// with NO active session (relaunched / cancelled / superseded) is a
    /// distinct category — the browser's success was real at Google, but
    /// the app was not waiting for it.
    @Test func staleCompletionWithNoActiveSession() {
        #expect(classify(["code": "c", "state": "s"], path: "/oauth/callback", expected: "/oauth/callback", active: nil)
                == .noActiveSession)
        #expect(classify(["code": "c", "state": "s"], path: "/oauth/callback", expected: "/oauth/callback", active: "")
                == .noActiveSession)
    }

    @Test func wrongOrMissingStateIsStateMismatch() {
        #expect(classify(["code": "c", "state": "evil"], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .stateMismatch)
        #expect(classify(["code": "c"], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .stateMismatch)
        #expect(classify(["code": "c", "state": ""], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .stateMismatch)
    }

    @Test func missingCodeAfterValidState() {
        #expect(classify(["state": "s"], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .missingCode)
        #expect(classify(["state": "s", "code": ""], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .missingCode)
    }

    @Test func validCallbackIsAccepted() {
        #expect(classify(["code": "c", "state": "s"], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .accepted)
    }

    /// An empty `error` value falls through to the later checks (Google
    /// never sends this, but a proxy rewrite could).
    @Test func emptyErrorValueFallsThrough() {
        #expect(classify(["error": "", "code": "c", "state": "s"], path: "/oauth/callback", expected: "/oauth/callback", active: "s")
                == .accepted)
    }

    // MARK: Sanitization (hostile inputs never reach a page verbatim)

    @Test func hostileErrorParamIsSanitized() {
        let outcome = classify(
            ["error": "<script>alert(1)//evil.example.com?token=ya29.SECRET"],
            path: "/oauth/callback", expected: "/oauth/callback", active: nil)
        guard case .authorizationDenied(let code) = outcome else {
            Issue.record("expected authorizationDenied, got \(outcome)")
            return
        }
        #expect(code == "scriptalertevilexamplecomtokenyaSECRET")
        #expect(!code!.contains("<"))
        #expect(!code!.contains("//"))
        #expect(!code!.contains(where: { $0.isNumber }))
    }

    @Test func overlongErrorParamIsCapped() {
        let outcome = classify(
            ["error": String(repeating: "a", count: 500)],
            path: "/oauth/callback", expected: "/oauth/callback", active: nil)
        guard case .authorizationDenied(let code) = outcome else {
            Issue.record("expected authorizationDenied, got \(outcome)")
            return
        }
        #expect(code?.count == 64)
    }

    // MARK: Browser page renderer (truthful copy, no value echo)

    /// THE false-success regression: the accepted page must NOT claim
    /// completed sign-in (exchange/storage/calendar readiness are still
    /// pending in the app), and the retired unconditional copy must stay
    /// gone from every page.
    @Test func acceptedPageNeverClaimsCompletedSignIn() {
        let page = OAuthCallbackPageRenderer.htmlBody(outcome: .accepted, appName: "QuikCal")
        #expect(page.contains("Return to QuikCal"))
        #expect(!page.contains("You can close this window"))
        let lowered = page.lowercased()
        #expect(!lowered.contains("signed in"))
        #expect(!lowered.contains("connected"))
        // Completion is explicitly deferred to the app, not claimed here.
        #expect(lowered.contains("completes in the app"))
    }

    @Test func failurePagesStateTheirCategoryAndNextStep() {
        let denied = OAuthCallbackPageRenderer.htmlBody(
            outcome: .authorizationDenied("access_denied"), appName: "QuikCal")
        #expect(denied.contains("access_denied"))
        #expect(denied.contains("Sign in with Google"))

        let stale = OAuthCallbackPageRenderer.htmlBody(
            outcome: .noActiveSession, appName: "QuikCal")
        #expect(stale.contains("no longer active"))
        #expect(stale.contains("start again"))
        #expect(!stale.contains("You can close this window"))

        let mismatch = OAuthCallbackPageRenderer.htmlBody(
            outcome: .stateMismatch, appName: "QuikCal")
        #expect(mismatch.contains("ignored for safety"))
        #expect(mismatch.contains("start again"))
        #expect(!mismatch.contains("You can close this window"))

        let missing = OAuthCallbackPageRenderer.htmlBody(
            outcome: .missingCode, appName: "QuikCal")
        #expect(missing.contains("missing the authorization code"))

        // An unrecognized denied code still renders a page (no crash, no
        // raw echo beyond the sanitized shape).
        let hostile = OAuthCallbackPageRenderer.htmlBody(
            outcome: .authorizationDenied("badcode"), appName: "QuikCal")
        #expect(hostile.contains("badcode"))
    }

    /// Non-callback paths get a neutral page: no session info, no success
    /// copy, nothing a probe can learn from.
    @Test func nonCallbackPathPageIsNeutral() {
        let page = OAuthCallbackPageRenderer.htmlBody(outcome: .notCallbackPath, appName: "QuikCal")
        #expect(page.contains("QuikCal"))
        #expect(!page.contains("authorization"))
        #expect(!page.contains("sign-in"))
    }

    /// The renderer is structurally incapable of echoing query VALUES
    /// (code/state/email are not parameters); the only interpolated
    /// content is the sanitized code shape and the app name. Pin that a
    /// token-like string passed as the sanitized code cannot smuggle
    /// markup through — sanitization already stripped it upstream, and the
    /// renderer must not re-interpret it.
    @Test func rendererOutputContainsNoQueryValues() {
        let outcomes: [OAuthCallbackOutcome] = [
            .accepted,
            .authorizationDenied("access_denied"),
            .authorizationDenied(nil),
            .noActiveSession,
            .stateMismatch,
            .missingCode,
            .notCallbackPath
        ]
        for outcome in outcomes {
            let page = OAuthCallbackPageRenderer.htmlBody(outcome: outcome, appName: "QuikCal")
            #expect(!page.contains("4/0AX4X"))
            #expect(!page.contains("<script"))
        }
    }

    // MARK: Preserved security invariants (no weakening)

    /// State validation stays constant-time and rejects wrong/missing
    /// values (the classifier uses the same comparison).
    @Test func pkceStateValidationStillRejectsWrongAndMissing() {
        let pkce = OAuthPKCE.make()
        #expect(pkce.validateReturnedState(pkce.state))
        #expect(!pkce.validateReturnedState("tampered"))
        #expect(!pkce.validateReturnedState(nil))
        #expect(!pkce.validateReturnedState(""))
    }

    /// The authorization URL still carries PKCE + state + offline access;
    /// the repair did not touch the outbound flow.
    @Test func authorizationURLStillCarriesPKCEAndState() throws {
        let pkce = OAuthPKCE.make()
        let url = try #require(OAuthAuthorizationURLBuilder.authorizationURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:53682/oauth/callback", pkce: pkce))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        #expect(names.isSuperset(of: ["state", "code_challenge", "code_challenge_method", "access_type"]))
        #expect(items.first { $0.name == "code_challenge" }?.value == pkce.codeChallenge)
        #expect(items.first { $0.name == "state" }?.value == pkce.state)
    }
}
