import Foundation
import Security

/// Thin wrapper around the macOS Keychain (`SecItem*`).
/// Ported from FaceGate-Mac with a configurable service name.
public final class KeychainHelper {
    public static let shared = KeychainHelper(service: FaceUnlockConfig.keychainService)

    private let service: String

    public init(service: String) {
        self.service = service
    }

    // MARK: - Public API

    /// Save data, overwriting any existing entry.
    public func save(_ data: Data, for account: String) throws {
        let query = baseQuery(for: account)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw FaceUnlockError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw FaceUnlockError.keychainError(updateStatus)
        }
    }

    /// Read data, or nil if the entry does not exist.
    public func read(for account: String) -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete an entry (no error if missing).
    public func delete(for account: String) {
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)
    }

    /// Whether an entry exists.
    public func exists(for account: String) -> Bool {
        read(for: account) != nil
    }

    // MARK: - Private

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
