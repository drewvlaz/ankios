import AnkiKit
import Foundation
import Security

/// Persists the sync host key in the Keychain (never the password).
enum CredentialStore {
    private static let service = "ankios.sync"
    private static let account = "default"

    static func load() -> SyncCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(SyncCredentials.self, from: data)
    }

    static func save(_ credentials: SyncCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            // Background sync runs after first unlock.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
