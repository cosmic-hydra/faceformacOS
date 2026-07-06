import CryptoKit
import Foundation

/// AES-256-GCM encryption/decryption helper using CryptoKit.
/// Ported from FaceGate, generalized from a singleton to an instance whose key
/// storage is injectable.
///
/// Key storage strategy:
/// - The key is kept in the login Keychain when available.
/// - Optionally it is *also* mirrored to a 0600 key file. This matters for the
///   enrollment template: the PAM helper must decrypt it in contexts (sudo,
///   screensaver) where the login Keychain may be locked or unreachable.
///   The vault key deliberately has no file mirror — autofill always runs in
///   an interactive user session where the Keychain works.
public final class CryptoHelper {
    private let keychain: KeychainHelper
    private let keychainAccount: String
    /// When set, the key is mirrored to (and readable from) this 0600 file.
    private let fallbackKeyFile: URL?

    public init(
        keychainAccount: String,
        keychain: KeychainHelper = KeychainHelper(),
        fallbackKeyFile: URL? = nil
    ) {
        self.keychainAccount = keychainAccount
        self.keychain = keychain
        self.fallbackKeyFile = fallbackKeyFile
    }

    // MARK: - Key Management

    /// Retrieve the encryption key (Keychain first, then key file), or
    /// generate and store a new one.
    public func getOrCreateKey() throws -> SymmetricKey {
        if let keyData = keychain.read(for: keychainAccount), keyData.count == 32 {
            mirrorToFileIfNeeded(keyData)
            return SymmetricKey(data: keyData)
        }

        if let file = fallbackKeyFile,
           let keyData = try? Data(contentsOf: file), keyData.count == 32 {
            // Key file exists but the Keychain entry doesn't (or is unreadable
            // right now) — best-effort re-mirror to the Keychain.
            try? keychain.save(keyData, for: keychainAccount)
            return SymmetricKey(data: keyData)
        }

        // No key anywhere — generate a fresh 256-bit key.
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }

        var storedSomewhere = false
        do {
            try keychain.save(keyData, for: keychainAccount)
            storedSomewhere = true
        } catch {
            // Keychain unavailable (e.g. PAM context) — the file fallback below
            // may still persist the key.
        }
        if writeKeyFile(keyData) {
            storedSomewhere = true
        }
        guard storedSomewhere else {
            throw CryptoError.keyStorageUnavailable
        }
        return newKey
    }

    /// Remove the key from every storage location.
    public func destroyKey() {
        keychain.delete(for: keychainAccount)
        if let file = fallbackKeyFile {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func mirrorToFileIfNeeded(_ keyData: Data) {
        guard let file = fallbackKeyFile,
              !FileManager.default.fileExists(atPath: file.path) else { return }
        _ = writeKeyFile(keyData)
    }

    @discardableResult
    private func writeKeyFile(_ keyData: Data) -> Bool {
        guard let file = fallbackKeyFile else { return false }
        do {
            try keyData.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt data using AES-256-GCM. Returns nonce + ciphertext + tag.
    public func encrypt(_ data: Data, using key: SymmetricKey? = nil) throws -> Data {
        let encryptionKey = try key ?? getOrCreateKey()
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    /// Decrypt AES-256-GCM sealed-box data (nonce + ciphertext + tag).
    public func decrypt(_ data: Data, using key: SymmetricKey? = nil) throws -> Data {
        let decryptionKey = try key ?? getOrCreateKey()
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: decryptionKey)
    }

    // MARK: - File Operations

    /// Encrypt data and write it to a file (0600).
    public func encryptToFile(_ data: Data, at url: URL) throws {
        let encrypted = try encrypt(data)
        try encrypted.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read and decrypt data from a file.
    public func decryptFromFile(at url: URL) throws -> Data {
        let encrypted = try Data(contentsOf: url)
        return try decrypt(encrypted)
    }
}

// MARK: - Errors

public enum CryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case keyStorageUnavailable

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        case .keyStorageUnavailable:
            return "Could not persist the encryption key to the Keychain or a key file"
        }
    }
}
