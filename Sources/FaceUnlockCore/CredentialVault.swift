import Foundation

/// Face-gated credential vault: labelled secrets, AES-256-GCM encrypted at
/// rest, with the vault key held **only** in the login Keychain (no key-file
/// mirror — unlike the enrollment template, the vault is only ever opened in
/// an interactive user session where the Keychain is available, and a key
/// file would let anything running as the user bypass the face gate).
///
/// The face gate itself is enforced by the callers (`faceunlock-autofill
/// get/type` run `FaceVerifier` before calling `secret(for:)`), not by this
/// class — see the README's security model for what that does and doesn't
/// protect against.
public final class CredentialVault {
    public enum VaultError: LocalizedError {
        case entryNotFound(String)
        case emptyVault
        case corruptVault

        public var errorDescription: String? {
            switch self {
            case .entryNotFound(let label):
                return "No credential stored under label \"\(label)\""
            case .emptyVault:
                return "The credential vault is empty — add one with: faceunlock-autofill set"
            case .corruptVault:
                return "Credential vault file could not be decoded"
            }
        }
    }

    private struct VaultEntry: Codable {
        var secret: String
        var updatedDate: Date
    }

    private struct VaultData: Codable {
        var entries: [String: VaultEntry] = [:]
    }

    public static let defaultLabel = "default"

    public let user: String?
    private let crypto: CryptoHelper
    private let filePath: URL

    public init(user: String?) {
        self.user = user
        self.filePath = FUConstants.vaultFilePath(forUser: user)
        self.crypto = CryptoHelper(
            keychainAccount: FUConstants.keychainVaultKeyAccount,
            fallbackKeyFile: nil
        )
    }

    // MARK: - Operations

    public func set(label: String, secret: String) throws {
        var data = try loadOrEmpty()
        data.entries[label] = VaultEntry(secret: secret, updatedDate: Date())
        try save(data)
    }

    public func secret(for label: String) throws -> String {
        let data = try loadOrEmpty()
        guard !data.entries.isEmpty else { throw VaultError.emptyVault }
        guard let entry = data.entries[label] else {
            throw VaultError.entryNotFound(label)
        }
        return entry.secret
    }

    public func labels() throws -> [String] {
        (try loadOrEmpty()).entries.keys.sorted()
    }

    public func remove(label: String) throws {
        var data = try loadOrEmpty()
        guard data.entries.removeValue(forKey: label) != nil else {
            throw VaultError.entryNotFound(label)
        }
        try save(data)
    }

    // MARK: - Persistence

    private func loadOrEmpty() throws -> VaultData {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return VaultData()
        }
        let plaintext = try crypto.decryptFromFile(at: filePath)
        do {
            return try JSONDecoder().decode(VaultData.self, from: plaintext)
        } catch {
            throw VaultError.corruptVault
        }
    }

    private func save(_ data: VaultData) throws {
        let plaintext = try JSONEncoder().encode(data)
        try crypto.encryptToFile(plaintext, at: filePath)
    }
}
