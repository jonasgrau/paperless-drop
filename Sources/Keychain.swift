import Foundation
import Security

/// Minimal wrapper for the one generic-password item holding the API token.
enum Keychain {
    static let service = "de.jonas.PaperlessDrop"
    static let account = "api-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasToken() -> Bool {
        // Asking only for attributes doesn't read the secret, so no access prompt.
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the stored token. True if it is gone afterwards, also when there was none.
    static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Replaces the stored token. Returns false if the Keychain refused.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Paperless Drop API token"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
