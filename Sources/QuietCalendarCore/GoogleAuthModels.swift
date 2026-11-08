import Foundation

/// Desktop OAuth client configuration. Never embeds a real client secret.
/// When `clientID` is empty, the UI must show an explicit unconfigured state.
public struct GoogleOAuthClientConfig: Sendable, Equatable, Codable {
    public var clientID: String
    /// Optional at the type level. CONFIRMED live (2026-11-07 owner
    /// diagnostic, names only: HTTP 400 `invalid_request`,
    /// `missing_parameter: client_secret`, `client_secret_sent: no`):
    /// Google's token endpoint requires it for Desktop-type clients even
    /// with correct PKCE. Supplied via `QUIET_CALENDAR_GOOGLE_CLIENT_SECRET`
    /// (explicit dev fallback) or a validated local JSON import persisted in
    /// the dedicated Keychain item; never bundled, never logged, never
    /// hardcoded.
    public var clientSecret: String
    public var redirectURI: String
    public var loopbackPort: Int

    public init(
        clientID: String = "",
        clientSecret: String = "",
        redirectURI: String = "http://127.0.0.1:53682/oauth/callback",
        loopbackPort: Int = 53682
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.loopbackPort = loopbackPort
    }

    public var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Loads from environment / bundle Info.plist without logging secrets.
    ///
    /// Resolution order: environment variable → bundled Info.plist key →
    /// unset (UI shows the explicit unconfigured state). This lets a packaged
    /// Finder launch work with no `export` at all: the build embeds the
    /// **public** Desktop OAuth client ID (`GoogleDesktopOAuthClientID`) in
    /// the app's Info.plist. The environment override stays useful for QA and
    /// alternate clients. No client secret is ever read or embedded.
    public static func fromEnvironment(
        clientIDKey: String = "QUIET_CALENDAR_GOOGLE_CLIENT_ID",
        redirectKey: String = "QUIET_CALENDAR_GOOGLE_REDIRECT_URI",
        clientSecretKey: String = "QUIET_CALENDAR_GOOGLE_CLIENT_SECRET",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any]? = Bundle.main.infoDictionary
    ) -> GoogleOAuthClientConfig {
        var config = GoogleOAuthClientConfig()
        let envID = environment[clientIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            config.clientID = envID
        } else if let bundledID = bundleInfo?[GoogleOAuthClientConfig.bundleClientIDKey] as? String {
            let trimmed = bundledID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { config.clientID = trimmed }
        }
        let envRedirect = environment[redirectKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envRedirect.isEmpty {
            config.redirectURI = envRedirect
        } else if let bundledRedirect = bundleInfo?[GoogleOAuthClientConfig.bundleRedirectKey] as? String,
                  !bundledRedirect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.redirectURI = bundledRedirect.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Secret: environment ONLY (never bundled, never logged, never
        // hardcoded). 2026-11-06: Google's token endpoint enforces
        // client_secret for Desktop clients even with PKCE, so an
        // owner-supplied secret is read here when present. The value is
        // consumed only by the token request body.
        let envSecret = environment[clientSecretKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envSecret.isEmpty {
            config.clientSecret = envSecret
        }
        return config
    }

    /// Info.plist key carrying the **public** Desktop OAuth client ID.
    /// Public by design (desktop clients are public; PKCE protects the flow);
    /// never place a client secret here.
    public static let bundleClientIDKey = "GoogleDesktopOAuthClientID"
    /// Optional Info.plist override for the loopback redirect URI.
    public static let bundleRedirectKey = "GoogleRedirectURI"
}

/// Concise onboarding Google copy (owner, 2026-11-06): one short sentence,
/// no scopes/jargon blocks.
public enum OnboardingGoogleCopy: Sendable {
    public static let subtitle = "Sign in to connect your calendar."
    public static let unconfiguredNote = "Google sign-in isn’t configured in this build yet."
}

public enum GoogleAuthPhase: String, Sendable, Equatable {
    case unconfigured
    case signedOut
    case authorizing
    case signedIn
    case error
}

/// Non-secret account metadata persisted in UserDefaults. Tokens stay in Keychain.
public struct GoogleLinkedAccount: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var email: String
    public var targetCalendarID: String?
    public var targetCalendarSummary: String?

    public init(
        id: String,
        email: String,
        targetCalendarID: String? = nil,
        targetCalendarSummary: String? = nil
    ) {
        self.id = id
        self.email = email
        self.targetCalendarID = targetCalendarID
        self.targetCalendarSummary = targetCalendarSummary
    }
}

public struct GoogleAccountDirectory: Sendable, Equatable, Codable {
    public var accounts: [GoogleLinkedAccount]

    public init(accounts: [GoogleLinkedAccount] = []) {
        self.accounts = accounts
    }

    public func account(id: String) -> GoogleLinkedAccount? {
        accounts.first { $0.id == id }
    }

    public mutating func upsert(_ account: GoogleLinkedAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
    }
}

public enum GoogleAccountDirectoryStore: Sendable {
    public static func load(from defaults: UserDefaults) -> GoogleAccountDirectory {
        guard let data = defaults.data(forKey: AppPreferenceKey.googleAccountsJSON) else {
            return GoogleAccountDirectory()
        }
        return (try? JSONDecoder().decode(GoogleAccountDirectory.self, from: data)) ?? GoogleAccountDirectory()
    }

    public static func save(_ directory: GoogleAccountDirectory, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(directory) else { return }
        defaults.set(data, forKey: AppPreferenceKey.googleAccountsJSON)
    }
}

/// Keychain account string is scoped per Google account id — never log token values.
public enum GoogleTokenKeychainAccount: Sendable {
    public static let service = "com.quietcalendar.app.google-oauth"

    public static func accountKey(forGoogleAccountID id: String) -> String {
        "google-account:\(id)"
    }
}

/// Token bundle persisted as ONE Keychain item per account (JSON-encoded).
/// The refresh token is the long-lived secret; the access token is cached
/// with its absolute expiry so API calls refresh only when needed.
public struct GoogleTokenBundle: Sendable, Equatable, Codable {
    public var refreshToken: String
    public var accessToken: String?
    public var accessTokenExpiresAt: Date?

    public init(refreshToken: String, accessToken: String? = nil, accessTokenExpiresAt: Date? = nil) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

/// Injectable token vault for tests (no Keychain required).
public protocol GoogleTokenVault: Sendable {
    func saveTokenBundle(_ bundle: GoogleTokenBundle, accountID: String) throws
    func loadTokenBundle(accountID: String) throws -> GoogleTokenBundle?
    func deleteTokens(accountID: String) throws
}

/// Test-friendly mutable vault (no Keychain).
public final class MutableInMemoryGoogleTokenVault: GoogleTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: GoogleTokenBundle] = [:]

    public init() {}

    public func saveTokenBundle(_ bundle: GoogleTokenBundle, accountID: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = bundle
    }

    public func loadTokenBundle(accountID: String) throws -> GoogleTokenBundle? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountID]
    }

    public func deleteTokens(accountID: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}

/// Scopes QuikCal requests. calendar.events (confirmed event create +
/// event read for the duplicate probe), calendar.readonly (CalendarList
/// listing/selection), openid email (account identity for Keychain keys).
public enum GoogleAuthorizationScopes: Sendable {
    public static let requested: [String] = [
        OAuthAuthorizationURLBuilder.calendarEventsScope,
        OAuthAuthorizationURLBuilder.calendarReadonlyScope,
        OAuthAuthorizationURLBuilder.openIDEmailScope
    ]
}

/// Resolves a usable access token for an account: cached while fresh (with a
/// 60-second clock skew), otherwise refreshed via the refresh grant and the
/// updated bundle persisted. `invalidGrant` surfaces as
/// `reauthorizationRequired` — tokens are NOT silently deleted; the user
/// decides to reconnect.
public struct GoogleAccessTokenProvider: Sendable {
    public var clientID: String
    /// Optional but currently enforced by Google for Desktop clients; sent
    /// only when non-empty. Never logged.
    public var clientSecret: String
    public var vault: GoogleTokenVault
    public var client: GoogleCalendarClient
    /// 60-second skew: treat tokens expiring within this window as expired.
    public var expirySkew: TimeInterval = 60

    public init(
        clientID: String,
        clientSecret: String = "",
        vault: GoogleTokenVault,
        client: GoogleCalendarClient
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.vault = vault
        self.client = client
    }

    public enum ProviderError: Error, Equatable, LocalizedError {
        case reauthorizationRequired
        case noStoredTokens
        public var errorDescription: String? {
            switch self {
            case .reauthorizationRequired: return GoogleAPIError.invalidGrant.errorDescription
            case .noStoredTokens: return "No stored Google tokens for this account."
            }
        }
    }

    public func accessToken(accountID: String) async throws -> String {
        guard let bundle = try vault.loadTokenBundle(accountID: accountID) else {
            throw ProviderError.noStoredTokens
        }
        let now = client.now()
        if let access = bundle.accessToken,
           let expiresAt = bundle.accessTokenExpiresAt,
           !access.isEmpty,
           now.addingTimeInterval(expirySkew) < expiresAt {
            return access
        }
        do {
            let grant = try await client.refreshAccessToken(
                refreshToken: bundle.refreshToken,
                clientID: clientID,
                clientSecret: clientSecret
            )
            var updated = bundle
            updated.accessToken = grant.accessToken
            updated.accessTokenExpiresAt = grant.expiresAt
            try vault.saveTokenBundle(updated, accountID: accountID)
            return grant.accessToken
        } catch let error as GoogleAPIError where error == .invalidGrant {
            throw ProviderError.reauthorizationRequired
        }
    }
}

/// Decides whether Google sign-in UI may proceed and what phase to show.
public enum GoogleAuthStateResolver: Sendable {
    public static func phase(
        config: GoogleOAuthClientConfig,
        hasLinkedAccounts: Bool,
        isAuthorizing: Bool,
        lastError: String?
    ) -> GoogleAuthPhase {
        if !config.isConfigured { return .unconfigured }
        if let lastError, !lastError.isEmpty { return .error }
        if isAuthorizing { return .authorizing }
        if hasLinkedAccounts { return .signedIn }
        return .signedOut
    }
}
