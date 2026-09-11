import Foundation
import Security

/// The GitHub token lives in the login keychain, not in UserDefaults, so it
/// never sits in a plain-text plist.
enum Keychain {
    private static let service = "com.kingprogress.app"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?

        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
