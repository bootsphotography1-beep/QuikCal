import Testing
import Foundation
@testable import QuietCalendarCore

/// 0.3.9: the owner-supplied **public** Desktop OAuth client ID ships inside
/// the app's Info.plist (`GoogleDesktopOAuthClientID`) so a packaged Finder
/// launch is configured without any environment export. The environment
/// variable override still wins. No client secret exists anywhere.
@Suite("Google client-ID bundle configuration (0.3.9)")
struct GoogleClientIDBundleConfigTests {

    private let bundledID = "823797884893-vajrcj282mkcgc57aduiovqtd3pnq35b.apps.googleusercontent.com"

    @Test("Bundle Info.plist client ID is used when env is unset")
    func usesBundleIDWhenEnvUnset() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            environment: [:],
            bundleInfo: [GoogleOAuthClientConfig.bundleClientIDKey: bundledID]
        )
        #expect(config.clientID == bundledID)
        #expect(config.isConfigured)
    }

    @Test("Environment override wins over bundled client ID")
    func envOverridesBundle() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            environment: ["QUIET_CALENDAR_GOOGLE_CLIENT_ID": "env-client-id"],
            bundleInfo: [GoogleOAuthClientConfig.bundleClientIDKey: bundledID]
        )
        #expect(config.clientID == "env-client-id")
    }

    @Test("Empty / whitespace env value falls back to bundle, not to unconfigured")
    func emptyEnvFallsBackToBundle() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            environment: ["QUIET_CALENDAR_GOOGLE_CLIENT_ID": "   "],
            bundleInfo: [GoogleOAuthClientConfig.bundleClientIDKey: "  \(bundledID)  "]
        )
        #expect(config.clientID == bundledID)
    }

    @Test("Whitespace-only bundle value never configures the client")
    func whitespaceBundleStaysUnconfigured() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            environment: [:],
            bundleInfo: [GoogleOAuthClientConfig.bundleClientIDKey: "   "]
        )
        #expect(!config.isConfigured)
    }

    @Test("Missing bundle info stays unconfigured — no fake state")
    func missingBundleStaysUnconfigured() {
        let config = GoogleOAuthClientConfig.fromEnvironment(
            environment: [:],
            bundleInfo: nil
        )
        #expect(!config.isConfigured)
        #expect(config.clientID.isEmpty)
    }

    @Test("Bundle redirect URI used only when env redirect unset")
    func bundleRedirectFallback() {
        let fromBundle = GoogleOAuthClientConfig.fromEnvironment(
            environment: [:],
            bundleInfo: [GoogleOAuthClientConfig.bundleRedirectKey: "http://127.0.0.1:60000/oauth/callback"]
        )
        #expect(fromBundle.redirectURI == "http://127.0.0.1:60000/oauth/callback")

        let envWins = GoogleOAuthClientConfig.fromEnvironment(
            environment: ["QUIET_CALENDAR_GOOGLE_REDIRECT_URI": "http://127.0.0.1:60001/oauth/callback"],
            bundleInfo: [GoogleOAuthClientConfig.bundleRedirectKey: "http://127.0.0.1:60000/oauth/callback"]
        )
        #expect(envWins.redirectURI == "http://127.0.0.1:60001/oauth/callback")
    }

    @Test("Default redirect unchanged when nothing overrides it")
    func defaultRedirectUnchanged() {
        let config = GoogleOAuthClientConfig.fromEnvironment(environment: [:], bundleInfo: [:])
        #expect(config.redirectURI == "http://127.0.0.1:53682/oauth/callback")
    }
}
