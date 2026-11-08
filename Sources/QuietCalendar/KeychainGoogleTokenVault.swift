import Foundation
import Security
import QuietCalendarCore

/// Stores Google token bundles (refresh + cached access token) in the
/// Keychain, keyed per account id. One JSON item per account under the
/// stable service `com.quietcalendar.app.google-oauth`. Never logs values.
struct KeychainGoogleTokenVault: GoogleTokenVault {
    func saveTokenBundle(_ bundle: GoogleTokenBundle, accountID: String) throws {
        let account = GoogleTokenKeychainAccount.accountKey(forGoogleAccountID: accountID)
        let data = try JSONEncoder().encode(bundle)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoogleTokenKeychainAccount.service,
            kSecAttrAccount as String: account
        ]
        // Update in place when present; otherwise add.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.unhandled(status)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    func loadTokenBundle(accountID: String) throws -> GoogleTokenBundle? {
        let account = GoogleTokenKeychainAccount.accountKey(forGoogleAccountID: accountID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoogleTokenKeychainAccount.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandled(status)
        }
        return try? JSONDecoder().decode(GoogleTokenBundle.self, from: data)
    }

    func deleteTokens(accountID: String) throws {
        let account = GoogleTokenKeychainAccount.accountKey(forGoogleAccountID: accountID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoogleTokenKeychainAccount.service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error (\(status))."
            }
        }
    }
}
