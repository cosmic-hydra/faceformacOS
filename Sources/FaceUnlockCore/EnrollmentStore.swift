import Foundation

/// Encrypted, file-backed storage for face enrollment data.
/// AES-256-GCM at rest via CryptoHelper; key lives in the user's Keychain.
public final class EnrollmentStore {
    private let crypto: CryptoHelper
    private let fileURL: URL

    /// - Parameters:
    ///   - dataDir: directory holding the encrypted enrollment file (created on demand).
    ///   - crypto: injectable for tests; defaults to the Keychain-backed enrollment key.
    public init(dataDir: URL = FaceUnlockConfig.dataDirectory(),
                crypto: CryptoHelper = CryptoHelper(keyAccount: FaceUnlockConfig.keychainEnrollmentKeyAccount)) {
        self.crypto = crypto
        self.fileURL = FaceUnlockConfig.enrollmentFile(dataDir: dataDir)
    }

    /// Whether an enrollment file exists on disk.
    public var hasEnrollment: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Persist an enrollment (encrypted).
    public func save(_ enrollment: FaceEnrollment) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(enrollment)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try crypto.encryptToFile(data, at: fileURL)
    }

    /// Load and decrypt the enrollment. Throws if missing or corrupt.
    public func load() throws -> FaceEnrollment {
        guard hasEnrollment else { throw FaceUnlockError.notEnrolled }

        let data = try crypto.decryptFromFile(at: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enrollment = try? decoder.decode(FaceEnrollment.self, from: data) else {
            throw FaceUnlockError.enrollmentInvalid
        }
        return enrollment
    }

    /// Delete the stored enrollment file (no error if absent).
    public func delete() throws {
        if hasEnrollment {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
