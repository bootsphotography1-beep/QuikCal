import Foundation
import Security
import QuietCalendarCore

/// Dedicated Keychain item for the privately imported Google Desktop client
/// secret (0.3.13). Separate service from the per-account token items so a
/// sign-out/reconnect can never touch it and vice versa.
///
/// Storage rules (owner constraints, 2026-11-07):
/// - ONE generic-password item under a FIXED structural account name. No
///   secret value in any attribute; no logging of the value.
/// - `kSecAttrAccessibleAfterFirstUnlock` matches the token vault.
/// - `save` updates in place when present (atomic from the API contract).
/// - `load` maps "never imported" to nil — not an error.
struct KeychainGoogleClientSecretStore: GoogleClientSecretPersisting {
    /// Dedicated service, distinct from `com.quietcalendar.app.google-oauth`.
    static let service = "com.quietcalendar.app.google-client-secret"
    /// Fixed structural account name (client identity of the single bundled
    /// Desktop client). Never a secret value; the client ID is public but is
    /// deliberately not used as an attribute to keep the item nameable.
    static let account = "google-desktop-client"

    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainStoreError.unhandled(status)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw KeychainStoreError.unhandled(updateStatus)
        }
    }

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainStoreError.unhandled(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }

    enum KeychainStoreError: LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error (\(status))."
            }
        }
    }
}

/// Test-friendly in-memory persisting fake (no Keychain). Records the ORDER
/// of mutations so validate-before-save atomicity is assertable.
final class InMemoryGoogleClientSecretStore: GoogleClientSecretPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    private(set) var operations: [String] = []

    func save(_ secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        operations.append("save")
        self.secret = secret
    }

    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        operations.append("load")
        return secret
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        operations.append("delete")
        secret = nil
    }
}
