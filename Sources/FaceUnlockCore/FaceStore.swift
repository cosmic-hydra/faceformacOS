import Foundation

/// Loads and saves the encrypted face-enrollment template for a user.
///
/// The template is AES-256-GCM encrypted. The key lives in the login
/// Keychain *and* is mirrored to a 0600 key file next to the template,
/// because the PAM helper must decrypt without an unlocked login Keychain.
public final class FaceStore {
    public enum StoreError: LocalizedError {
        case noEnrollment(String)
        case corruptEnrollment

        public var errorDescription: String? {
            switch self {
            case .noEnrollment(let path):
                return "No face enrollment found at \(path) — run faceunlock-enroll first"
            case .corruptEnrollment:
                return "Face enrollment file could not be decoded"
            }
        }
    }

    public let user: String?
    private let crypto: CryptoHelper
    private let filePath: URL

    public init(user: String?) {
        self.user = user
        self.filePath = FUConstants.enrollmentFilePath(forUser: user)
        self.crypto = CryptoHelper(
            keychainAccount: FUConstants.keychainEnrollmentKeyAccount,
            fallbackKeyFile: FUConstants.enrollmentKeyFilePath(forUser: user)
        )
    }

    public var hasEnrollment: Bool {
        FileManager.default.fileExists(atPath: filePath.path)
    }

    public func loadEnrollment() throws -> FaceEnrollment {
        guard hasEnrollment else {
            throw StoreError.noEnrollment(filePath.path)
        }
        let data = try crypto.decryptFromFile(at: filePath)
        do {
            return try JSONDecoder().decode(FaceEnrollment.self, from: data)
        } catch {
            throw StoreError.corruptEnrollment
        }
    }

    public func saveEnrollment(_ enrollment: FaceEnrollment) throws {
        let data = try JSONEncoder().encode(enrollment)
        try crypto.encryptToFile(data, at: filePath)
    }

    /// Delete the enrollment template (keeps the key, so a re-enroll reuses it).
    public func deleteEnrollment() {
        try? FileManager.default.removeItem(at: filePath)
    }

    /// Delete the enrollment and destroy its encryption key everywhere.
    public func purge() {
        deleteEnrollment()
        crypto.destroyKey()
    }
}
