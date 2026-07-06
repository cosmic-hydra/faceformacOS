import Foundation

/// Face-gated credential vault: named secrets, AES-256-GCM encrypted at rest,
/// with the vault key held in the user's Keychain.
///
/// The vault itself does no face matching — callers (the `faceunlock-autofill`
/// CLI) must run `FaceVerifier` before releasing a secret.
public final class CredentialVault {
    public struct Entry: Codable {
        public let name: String
        public var secret: String
        public let createdDate: Date
        public var modifiedDate: Date
    }

    private struct VaultFile: Codable {
        var entries: [Entry]
    }

    private let crypto: CryptoHelper
    private let fileURL: URL

    public init(dataDir: URL = FaceUnlockConfig.dataDirectory(),
                crypto: CryptoHelper = CryptoHelper(keyAccount: FaceUnlockConfig.keychainVaultKeyAccount)) {
        self.crypto = crypto
        self.fileURL = FaceUnlockConfig.vaultFile(dataDir: dataDir)
    }

    // MARK: - Operations

    /// Store (or overwrite) a named secret.
    public func set(name: String, secret: String) throws {
        var vault = try loadOrEmpty()
        let now = Date()
        if let index = vault.entries.firstIndex(where: { $0.name == name }) {
            vault.entries[index].secret = secret
            vault.entries[index].modifiedDate = now
        } else {
            vault.entries.append(Entry(name: name, secret: secret, createdDate: now, modifiedDate: now))
        }
        try persist(vault)
    }

    /// Retrieve a secret by name.
    public func get(name: String) throws -> String {
        let vault = try loadOrEmpty()
        guard let entry = vault.entries.first(where: { $0.name == name }) else {
            throw FaceUnlockError.secretNotFound(name)
        }
        return entry.secret
    }

    /// Names of all stored secrets (never the secrets themselves).
    public func list() throws -> [String] {
        try loadOrEmpty().entries.map(\.name).sorted()
    }

    /// Remove a secret by name.
    public func remove(name: String) throws {
        var vault = try loadOrEmpty()
        guard vault.entries.contains(where: { $0.name == name }) else {
            throw FaceUnlockError.secretNotFound(name)
        }
        vault.entries.removeAll { $0.name == name }
        try persist(vault)
    }

    /// Whether the vault file exists.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Private

    private func loadOrEmpty() throws -> VaultFile {
        guard exists else { return VaultFile(entries: []) }
        let data = try crypto.decryptFromFile(at: fileURL)
        return try JSONDecoder().decode(VaultFile.self, from: data)
    }

    private func persist(_ vault: VaultFile) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(vault)
        try crypto.encryptToFile(data, at: fileURL)
    }
}
