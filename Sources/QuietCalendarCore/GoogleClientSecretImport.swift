import Foundation

// MARK: - Local Google Desktop client-JSON import (0.3.13)
//
// 2026-11-07 live evidence (owner diagnostic, values never captured): the
// Google token endpoint returned HTTP 400 `invalid_request` with
// `missing_parameter: client_secret` while `client_secret_sent: no`. The
// bundled app carries only the PUBLIC client ID, so a Finder launch has no
// secret and sign-in cannot complete. The robust owner-side path is a small,
// explicit, local import: the owner picks the Google Cloud Console
// "Desktop app" JSON they downloaded (NSOpenPanel — the app never scans or
// reads arbitrary files, and never reads the owner's credential JSON without
// the user picking it), the app validates it STRICTLY, and the secret is
// stored in a DEDICATED Keychain item (never NSUserDefaults, never the
// bundle, never an artifact, never logged).
//
// Security invariants (all pinned by tests):
// - Validate fully BEFORE any Keychain write; on failure nothing changes —
//   the previous Keychain item and in-memory config are preserved.
// - The JSON's `client_id` must EXACTLY match the bound (bundled/active)
//   client ID — an incompatible client is rejected with a reason, never
//   adopted.
// - Strict shape: exactly one root key, which must be `installed` (Desktop
//   type); `web` (server flow — incompatible redirect model) is rejected;
//   hard byte cap; no key:value content reaches the UI, logs, or errors.
// - The environment variable stays ONLY as the explicit dev fallback and is
//   respected first when present.

public struct ImportedGoogleClientConfiguration: Sendable, Equatable {
    /// Public client ID — safe to surface (it is public by design).
    public let clientID: String
    /// The secret itself; never logged, never echoed by error messages.
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// Failure reasons are STRUCTURAL NAMES only — no file content, no id, no
/// secret can ever appear in any error message.
public enum GoogleClientSecretImportError: Error, Equatable, LocalizedError {
    case emptyFile
    case tooLarge(maxBytes: Int)
    case unusableJSON
    /// Root had no `installed` object at all (e.g. nothing, or unknown type).
    case missingInstalledObject
    /// Root contained `web` — a Web-type client uses a server-flow redirect
    /// model incompatible with this app's loopback design; rejected, and the
    /// owner is pointed at the Desktop (installed) JSON instead.
    case incompatibleWebClient
    case missingClientID
    case missingClientSecret
    case clientIDNotMatchingBoundConfig
    case secretTooLong

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .tooLarge:
            return "The selected file is much larger than a Google client download — pick the exact downloaded JSON."
        case .unusableJSON:
            return "The selected file is not valid JSON — pick the JSON file downloaded from Google Cloud Console."
        case .missingInstalledObject:
            return "This JSON is not a Desktop-type client download — in Google Cloud Console make sure the client type is “Desktop app”, then download its JSON again."
        case .incompatibleWebClient:
            return "This is a Web-type client download. QuikCal needs a Desktop app — in Google Cloud Console select a “Desktop app” client and download its JSON."
        case .missingClientID:
            return "The file has no client_id — download the client's JSON from Google Cloud Console again."
        case .missingClientSecret:
            return "The file has no client_secret — download the client's JSON from Google Cloud Console again."
        case .clientIDNotMatchingBoundConfig:
            return "The file is for a different Google client than the one bundled with QuikCal. Use the JSON that matches the bundled client (or the owner-approved client)."
        case .secretTooLong:
            return "The file's secret field is longer than any real Google client secret — pick the downloaded JSON again."
        }
    }
}

/// Private Keychain persistence seam for the imported client secret.
/// Implementations store ONLY the secret; the dedicated Keychain store (app
/// layer) keys the item by a FIXED structural account name — no secret values
/// in attributes, no logging. Tests inject a fake.
public protocol GoogleClientSecretPersisting: Sendable {
    /// Replaces the stored secret. Implementations must be atomic from the
    /// caller's perspective (validate-before-save happens above this seam).
    func save(_ secret: String) throws
    /// nil when no secret was ever imported (item absent), NOT an error.
    func load() throws -> String?
    func delete() throws
}

/// Strict validation of a user-selected Google Cloud Console client JSON.
/// Pure — no I/O, no Keychain, no network. Rejects BEFORE any state change.
public enum GoogleClientSecretJSONImporter: Sendable {
    /// A real "Desktop app" download is ~300–500 bytes; generous hard cap
    /// keeps any hostile selection bounded without risking future keys.
    public static let maxFileBytes: Int = 64 * 1024
    static let maxSecretLength = 512
    static let maxClientIDLength = 128
    static let clientIDSuffix = "apps.googleusercontent.com"

    /// Validates and extracts. Throws on ANY structural problem; a throw
    /// guarantees the caller has not yet written anything anywhere.
    public static func validate(
        _ data: Data,
        boundClientID: String
    ) throws -> ImportedGoogleClientConfiguration {
        guard !data.isEmpty else { throw GoogleClientSecretImportError.emptyFile }
        guard data.count <= maxFileBytes else {
            throw GoogleClientSecretImportError.tooLarge(maxBytes: maxFileBytes)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw GoogleClientSecretImportError.unusableJSON
        }
        // Exactly one client description (the downloaded shape). `installed`
        // = Desktop type (the supported flow). `web` = server flow —
        // explicitly incompatible, named so the owner knows what to change.
        guard root.count == 1, let key = root.keys.first else {
            throw GoogleClientSecretImportError.missingInstalledObject
        }
        switch key {
        case "installed":
            break
        case "web":
            throw GoogleClientSecretImportError.incompatibleWebClient
        default:
            throw GoogleClientSecretImportError.missingInstalledObject
        }
        guard let client = root[key] as? [String: Any] else {
            throw GoogleClientSecretImportError.missingInstalledObject
        }
        guard let rawID = client["client_id"] as? String else {
            throw GoogleClientSecretImportError.missingClientID
        }
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty,
              clientID.count <= maxClientIDLength,
              clientID.hasSuffix(clientIDSuffix)
        else {
            throw GoogleClientSecretImportError.missingClientID
        }
        let bound = boundClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact match against the app's bound client (bundled public ID or
        // explicit env override). A different client is a hard reject.
        if !bound.isEmpty, bound != clientID {
            throw GoogleClientSecretImportError.clientIDNotMatchingBoundConfig
        }
        // Redirect URIs, when present, must be an array of plain strings
        // (shape check only — values are never read or surfaced).
        if let redirects = client["redirect_uris"], !(redirects is [String]) {
            throw GoogleClientSecretImportError.missingInstalledObject
        }
        guard let rawSecret = client["client_secret"] as? String else {
            throw GoogleClientSecretImportError.missingClientSecret
        }
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw GoogleClientSecretImportError.missingClientSecret }
        guard secret.count <= maxSecretLength else { throw GoogleClientSecretImportError.secretTooLong }
        return ImportedGoogleClientConfiguration(clientID: clientID, clientSecret: secret)
    }
}

/// Ordered adoption of a validated file import: validate → write Keychain →
/// hand the result back. The caller adopts the in-memory config ONLY after
/// both steps succeeded, so a failure anywhere preserves the previous
/// Keychain item AND the previous in-memory configuration.
public struct GoogleClientSecretImportService<Store: GoogleClientSecretPersisting>: Sendable {
    public let persisting: Store

    public init(persisting: Store) {
        self.persisting = persisting
    }

    /// Full import for a file the user picked in the app. Runs off the main
    /// thread in production (file read + validation + Keychain write); pure
    /// logic here, so tests exercise ordering directly with a recording fake.
    public func importConfiguration(
        fileData: Data,
        boundClientID: String
    ) throws -> ImportedGoogleClientConfiguration {
        // 1. Validate COMPLETELY first. Any throw here has touched nothing.
        let imported = try GoogleClientSecretJSONImporter.validate(
            fileData, boundClientID: boundClientID)
        // 2. Only a fully validated import reaches the Keychain; the
        //    dedicated store is the single persistence sink.
        try persisting.save(imported.clientSecret)
        return imported
    }
}

/// Resolution precedence for the client secret: an explicitly exported
/// environment variable (dev fallback) is respected first; otherwise the
/// locally imported Keychain value; otherwise nothing. Pure, so the ordering
/// is pinned by tests and shared by launch adoption.
public enum GoogleClientSecretResolutionPolicy: Sendable {
    public static func resolve(
        environmentSecret: String?,
        storedSecret: String?
    ) -> String? {
        let env = environmentSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let stored = storedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return nil
    }
}
