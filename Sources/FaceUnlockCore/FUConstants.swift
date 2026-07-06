import Foundation

/// Constants and per-user path resolution for the FaceUnlock pipeline.
///
/// Unlike the FaceGate app (which only ever runs as the logged-in user), the
/// headless tools may be invoked by the PAM module for a *named* user, so every
/// path helper takes an optional user name and resolves against that user's
/// home directory (falling back to the current process's home).
public enum FUConstants {
    // MARK: - Keychain

    /// Keychain service name for all FaceUnlock entries.
    public static let keychainService = "com.faceformacos.FaceUnlock"

    /// Keychain account key for the face-enrollment encryption key.
    public static let keychainEnrollmentKeyAccount = "faceDataEncryptionKey"

    /// Keychain account key for the credential-vault encryption key.
    public static let keychainVaultKeyAccount = "credentialVaultKey"

    // MARK: - Matching / capture defaults

    /// Default cosine-similarity threshold (same tuning as FaceGate).
    public static let defaultFaceUnlockThreshold: Float = 0.65

    /// Default verification timeout in seconds.
    public static let defaultVerifyTimeout: TimeInterval = 10

    /// Number of matching frames required before verification succeeds.
    /// Requiring several consecutive-ish matches filters out one-frame flukes.
    public static let requiredMatchFrames = 3

    /// Number of face frames captured during enrollment.
    public static let defaultEnrollmentFrameCount = 9

    /// Minimum Vision face-capture quality (0–1) for a frame to be used.
    public static let minimumCaptureQuality: Float = 0.35

    /// Expected embedding dimension (MobileFaceNet / InsightFace w600k).
    public static let embeddingDimension = 512

    // MARK: - Install locations

    /// Where the install script places the verify helper (the PAM module
    /// execs this exact absolute path).
    public static let verifyHelperInstallPath = "/usr/local/bin/faceunlock-verify"

    // MARK: - Path resolution

    /// Home directory for `user`, or the current process's home when `user`
    /// is nil / unresolvable.
    public static func homeDirectory(forUser user: String?) -> URL {
        if let user, !user.isEmpty, let home = NSHomeDirectoryForUser(user) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Application Support/FaceUnlock` for the given user.
    /// Created (0700) on first access.
    public static func appSupportDirectory(forUser user: String?) -> URL {
        let dir = homeDirectory(forUser: user)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("FaceUnlock", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    /// Encrypted face-enrollment template.
    public static func enrollmentFilePath(forUser user: String?) -> URL {
        appSupportDirectory(forUser: user).appendingPathComponent("enrollment.encrypted")
    }

    /// Fallback key file for the enrollment encryption key (0600). Needed
    /// because the login Keychain is not reliably available in a PAM context.
    public static func enrollmentKeyFilePath(forUser user: String?) -> URL {
        appSupportDirectory(forUser: user).appendingPathComponent(".enrollment.key")
    }

    /// Encrypted credential vault.
    public static func vaultFilePath(forUser user: String?) -> URL {
        appSupportDirectory(forUser: user).appendingPathComponent("vault.encrypted")
    }

    /// Compiled Core ML face-embedding model (a `.mlmodelc` *directory*),
    /// copied here by `faceunlock-enroll` / `scripts/install.sh`.
    public static func modelPath(forUser user: String?) -> URL {
        appSupportDirectory(forUser: user).appendingPathComponent("model.mlmodelc", isDirectory: true)
    }
}
