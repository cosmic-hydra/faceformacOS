import Foundation

/// Central configuration: file locations, Keychain identifiers, and tunable defaults.
public enum FaceUnlockConfig {
    // MARK: - Keychain

    /// Keychain service name for all faceformacOS entries.
    public static let keychainService = "com.faceformacos.faceunlock"

    /// Keychain account for the enrollment-data encryption key.
    public static let keychainEnrollmentKeyAccount = "enrollmentEncryptionKey"

    /// Keychain account for the credential-vault encryption key.
    public static let keychainVaultKeyAccount = "vaultEncryptionKey"

    // MARK: - Matching / liveness defaults

    /// Default cosine-similarity threshold (same balance as FaceGate).
    public static let defaultMatchThreshold: Float = 0.65

    /// Default number of consecutive matching frames required before liveness starts.
    public static let requiredConsecutiveMatches = 2

    /// Yaw (radians) the head must turn to satisfy a turn challenge.
    public static let turnYawThreshold: Float = 0.12

    /// Eye-aspect-ratio below which the eye is considered closed (blink).
    public static let blinkClosedEAR: Float = 0.16

    /// Eye-aspect-ratio above which the eye is considered open.
    public static let blinkOpenEAR: Float = 0.24

    /// Default verification timeout in seconds.
    public static let defaultVerifyTimeout: TimeInterval = 10

    /// Number of enrollment samples per pose (straight, left, right).
    public static let enrollmentSamplesPerPose = 3

    /// Minimum Vision capture-quality score accepted during enrollment.
    public static let minimumEnrollmentQuality: Float = 0.35

    // MARK: - Paths

    /// Per-user data directory: `~/Library/Application Support/faceunlock`.
    /// Honors `FACEUNLOCK_DATA_DIR` for tests and custom setups.
    public static func dataDirectory(override: String? = nil) -> URL {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["FACEUNLOCK_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("faceunlock", isDirectory: true)
    }

    /// Encrypted face-enrollment file inside the data directory.
    public static func enrollmentFile(dataDir: URL) -> URL {
        dataDir.appendingPathComponent("face_data.encrypted")
    }

    /// Encrypted credential-vault file inside the data directory.
    public static func vaultFile(dataDir: URL) -> URL {
        dataDir.appendingPathComponent("vault.encrypted")
    }

    /// Candidate locations for the compiled Core ML embedding model, in priority order.
    /// - Parameter override: explicit `--model` path from the CLI.
    public static func modelSearchPaths(override: String? = nil) -> [URL] {
        var candidates: [URL] = []

        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        if let env = ProcessInfo.processInfo.environment["FACEUNLOCK_MODEL"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }

        let modelName = "FaceEmbedding.mlmodelc"
        candidates.append(dataDirectory().appendingPathComponent(modelName))
        candidates.append(URL(fileURLWithPath: "/usr/local/share/faceunlock/\(modelName)"))
        candidates.append(URL(fileURLWithPath: "/opt/faceunlock/share/\(modelName)"))

        // Development fallback: running from a checkout of this repo.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("FaceGate/ML/\(modelName)"))

        return candidates
    }

    /// Resolve the first existing model path, or nil.
    public static func resolveModelPath(override: String? = nil) -> URL? {
        modelSearchPaths(override: override).first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
