import Foundation
import Security

/// Wrapper around the macOS Keychain for secure key storage.
/// Ported from FaceGate, generalized from a singleton to an instance so the
/// service name is injectable.
public final class KeychainHelper {
    public let service: String

    public init(service: String = FUConstants.keychainService) {
        self.service = service
    }

    // MARK: - Public API

    /// Save data to the Keychain. Overwrites an existing entry if present.
    public func save(_ data: Data, for account: String) throws {
        let query = baseQuery(for: account)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unableToSave(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unableToSave(status: updateStatus)
        }
    }

    /// Read data from the Keychain. Returns nil if not found or inaccessible
    /// (e.g. locked keychain in a PAM context).
    public func read(for account: String) -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete an entry from the Keychain.
    public func delete(for account: String) {
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)
    }

    /// Check whether an entry exists.
    public func exists(for account: String) -> Bool {
        read(for: account) != nil
    }

    // MARK: - Convenience (String)

    public func saveString(_ string: String, for account: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        try save(data, for: account)
    }

    public func readString(for account: String) -> String? {
        guard let data = read(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
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

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case unableToSave(status: OSStatus)
    case encodingError

    public var errorDescription: String? {
        switch self {
        case .unableToSave(let status):
            return "Keychain save failed with status: \(status)"
        case .encodingError:
            return "Failed to encode data for Keychain storage"
        }
    }
}
