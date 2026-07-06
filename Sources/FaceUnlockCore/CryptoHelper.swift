import CryptoKit
import Foundation

/// AES-256-GCM encryption/decryption with the key held in the macOS Keychain.
/// Ported from FaceGate-Mac; the Keychain account is injectable so the
/// enrollment store and the credential vault use independent keys, and tests
/// can supply a fixed key without touching the Keychain.
public final class CryptoHelper {
    private let keychain: KeychainHelper
    private let keyAccount: String
    private let fixedKey: SymmetricKey?

    /// Production initializer: key is loaded from / created in the Keychain.
    public init(keychain: KeychainHelper = .shared, keyAccount: String) {
        self.keychain = keychain
        self.keyAccount = keyAccount
        self.fixedKey = nil
    }

    /// Test initializer: a caller-supplied key, bypassing the Keychain entirely.
    public init(fixedKey: SymmetricKey) {
        self.keychain = .shared
        self.keyAccount = ""
        self.fixedKey = fixedKey
    }

    // MARK: - Key Management

    /// Retrieve the encryption key from the Keychain, or generate and store a new one.
    public func getOrCreateKey() throws -> SymmetricKey {
        if let fixedKey { return fixedKey }

        if let existing = keychain.read(for: keyAccount) {
            return SymmetricKey(data: existing)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try keychain.save(keyData, for: keyAccount)
        return newKey
    }

    /// Remove the key from the Keychain (used by uninstall / reset flows).
    public func destroyKey() {
        guard fixedKey == nil else { return }
        keychain.delete(for: keyAccount)
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt with AES-256-GCM. Returns nonce + ciphertext + tag.
    public func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw FaceUnlockError.encryptionFailed
        }
        return combined
    }

    /// Decrypt AES-256-GCM sealed-box data.
    public func decrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw FaceUnlockError.decryptionFailed
        }
    }

    // MARK: - File Operations

    /// Encrypt data and write it atomically with owner-only permissions.
    public func encryptToFile(_ data: Data, at url: URL) throws {
        let encrypted = try encrypt(data)
        try encrypted.write(to: url, options: [.atomic])
        // Restrict to the owning user (0600) — the store lives in the user's home.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read and decrypt a file.
    public func decryptFromFile(at url: URL) throws -> Data {
        let encrypted = try Data(contentsOf: url)
        return try decrypt(encrypted)
    }
}
