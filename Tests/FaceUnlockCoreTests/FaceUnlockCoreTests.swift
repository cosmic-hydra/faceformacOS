import CryptoKit
import Foundation
import Testing
@testable import FaceUnlockCore

// MARK: - VectorMath

@Suite struct VectorMathTests {
    @Test func cosineSimilarityIdenticalVectors() {
        let v: [Float] = [0.5, 0.5, 0.5, 0.5]
        #expect(abs(VectorMath.cosineSimilarity(v, v) - 1.0) < 1e-5)
    }

    @Test func cosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        #expect(abs(VectorMath.cosineSimilarity(a, b)) < 1e-5)
    }

    @Test func cosineSimilarityOppositeVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        #expect(abs(VectorMath.cosineSimilarity(a, b) - (-1.0)) < 1e-5)
    }

    @Test func cosineSimilarityMismatchedLengths() {
        #expect(VectorMath.cosineSimilarity([1, 2], [1, 2, 3]) == -1.0)
    }

    @Test func cosineSimilarityEmptyVectors() {
        #expect(VectorMath.cosineSimilarity([], []) == -1.0)
    }

    @Test func euclideanDistance() {
        let a: [Float] = [0, 0]
        let b: [Float] = [3, 4]
        #expect(abs(VectorMath.euclideanDistance(a, b) - 5.0) < 1e-5)
    }

    @Test func normalize() {
        let normalized = VectorMath.normalize([3, 4] as [Float])
        #expect(abs(normalized[0] - 0.6) < 1e-5)
        #expect(abs(normalized[1] - 0.8) < 1e-5)

        let magnitude = sqrt(normalized.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 1e-5)
    }

    @Test func normalizeZeroVector() {
        let v: [Float] = [0, 0, 0]
        #expect(VectorMath.normalize(v) == v)
    }
}

// MARK: - CryptoHelper

@Suite struct CryptoHelperTests {
    private let crypto = CryptoHelper(fixedKey: SymmetricKey(size: .bits256))

    @Test func encryptDecryptRoundtrip() throws {
        let plaintext = Data("face embedding payload".utf8)
        let encrypted = try crypto.encrypt(plaintext)
        #expect(encrypted != plaintext)
        #expect(try crypto.decrypt(encrypted) == plaintext)
    }

    @Test func decryptWithWrongKeyFails() throws {
        let encrypted = try crypto.encrypt(Data("secret".utf8))
        let otherCrypto = CryptoHelper(fixedKey: SymmetricKey(size: .bits256))
        #expect(throws: FaceUnlockError.decryptionFailed) {
            try otherCrypto.decrypt(encrypted)
        }
    }

    @Test func decryptGarbageFails() {
        #expect(throws: (any Error).self) {
            try crypto.decrypt(Data([0x01, 0x02, 0x03]))
        }
    }

    @Test func fileRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceunlock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("blob.encrypted")
        let payload = Data("on-disk payload".utf8)

        try crypto.encryptToFile(payload, at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Encrypted at rest.
        let raw = try Data(contentsOf: url)
        #expect(raw != payload)

        // Owner-only permissions.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

        #expect(try crypto.decryptFromFile(at: url) == payload)
    }
}

// MARK: - FaceMatcher

@Suite struct FaceMatcherTests {
    @Test func exactMatchPasses() {
        let matcher = FaceMatcher(threshold: 0.65)
        let embedding = VectorMath.normalize((0..<512).map { Float($0) / 512.0 })
        let result = matcher.match(liveEmbedding: embedding, against: [embedding])
        #expect(result.isMatch)
        #expect(abs(result.bestSimilarity - 1.0) < 1e-4)
    }

    @Test func dissimilarFaceFails() {
        let matcher = FaceMatcher(threshold: 0.65)
        var a = [Float](repeating: 0, count: 512); a[0] = 1
        var b = [Float](repeating: 0, count: 512); b[1] = 1
        #expect(!matcher.match(liveEmbedding: a, against: [b]).isMatch)
    }

    @Test func emptyEnrollmentFails() {
        let matcher = FaceMatcher(threshold: 0.65)
        let result = matcher.match(liveEmbedding: [1, 0], against: [])
        #expect(!result.isMatch)
        #expect(result.bestSimilarity == -1.0)
    }

    @Test func bestOfMultipleEmbeddings() {
        let matcher = FaceMatcher(threshold: 0.9)
        let live: [Float] = VectorMath.normalize([1, 1, 0, 0])
        let far: [Float] = VectorMath.normalize([0, 0, 1, 1])
        let near: [Float] = VectorMath.normalize([1, 0.9, 0, 0])
        let result = matcher.match(liveEmbedding: live, against: [far, near])
        #expect(result.isMatch)
        #expect(result.bestSimilarity > 0.9)
    }

    @Test func thresholdClamping() {
        let matcher = FaceMatcher(threshold: 5.0)  // clamped to 1.0
        let embedding: [Float] = VectorMath.normalize([1, 2, 3])
        let result = matcher.match(liveEmbedding: embedding, against: [embedding])
        #expect(result.threshold == 1.0)
        #expect(result.isMatch)  // similarity 1.0 >= 1.0
    }

    @Test func centroidMatch() {
        let matcher = FaceMatcher(threshold: 0.8)
        let a: [Float] = VectorMath.normalize([1, 0.1, 0, 0])
        let b: [Float] = VectorMath.normalize([1, -0.1, 0, 0])
        let live: [Float] = VectorMath.normalize([1, 0, 0, 0])
        #expect(matcher.matchAgainstCentroid(liveEmbedding: live, enrolledEmbeddings: [a, b]).isMatch)
    }
}

// MARK: - EnrollmentStore

@Suite struct EnrollmentStoreTests {
    private func withStore(_ body: (EnrollmentStore, URL) throws -> Void) throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceunlock-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = EnrollmentStore(dataDir: dataDir,
                                    crypto: CryptoHelper(fixedKey: SymmetricKey(size: .bits256)))
        try body(store, dataDir)
    }

    private func makeEnrollment(samples: Int = 3) -> FaceEnrollment {
        let embeddings = (0..<samples).map { i in
            VectorMath.normalize((0..<512).map { Float(($0 + i) % 97) / 97.0 })
        }
        return FaceEnrollment(faces: [
            .init(name: "Test Face", embeddings: embeddings, averageQuality: 0.8)
        ])
    }

    @Test func saveLoadRoundtrip() throws {
        try withStore { store, _ in
            #expect(!store.hasEnrollment)
            try store.save(makeEnrollment())
            #expect(store.hasEnrollment)

            let loaded = try store.load()
            #expect(loaded.faces.count == 1)
            #expect(loaded.faces[0].name == "Test Face")
            #expect(loaded.faces[0].embeddings.count == 3)
            #expect(loaded.isValid)
        }
    }

    @Test func loadWithoutEnrollmentThrows() throws {
        try withStore { store, _ in
            #expect(throws: FaceUnlockError.notEnrolled) { try store.load() }
        }
    }

    @Test func deleteEnrollment() throws {
        try withStore { store, _ in
            try store.save(makeEnrollment())
            #expect(store.hasEnrollment)
            try store.delete()
            #expect(!store.hasEnrollment)
            try store.delete()  // deleting again is a no-op
        }
    }

    @Test func enrollmentValidity() {
        #expect(!FaceEnrollment(faces: []).isValid)
        #expect(!makeEnrollment(samples: 2).isValid)
        #expect(makeEnrollment(samples: 3).isValid)
    }

    @Test func legacySingleFaceDecoding() throws {
        // FaceGate's legacy single-face JSON layout.
        let legacyJSON = """
        {
            "embeddings": [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]],
            "enrolledDate": "2024-01-15T10:30:00Z",
            "averageQuality": 0.75
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let enrollment = try decoder.decode(FaceEnrollment.self, from: Data(legacyJSON.utf8))
        #expect(enrollment.faces.count == 1)
        #expect(enrollment.faces[0].embeddings.count == 3)
        #expect(enrollment.faces[0].averageQuality == 0.75)
    }
}

// MARK: - CredentialVault

@Suite struct CredentialVaultTests {
    private func withVault(_ body: (CredentialVault, URL) throws -> Void) throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceunlock-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let vault = CredentialVault(dataDir: dataDir,
                                    crypto: CryptoHelper(fixedKey: SymmetricKey(size: .bits256)))
        try body(vault, dataDir)
    }

    @Test func setGetRoundtrip() throws {
        try withVault { vault, _ in
            try vault.set(name: "github", secret: "hunter2")
            #expect(try vault.get(name: "github") == "hunter2")
        }
    }

    @Test func overwrite() throws {
        try withVault { vault, _ in
            try vault.set(name: "github", secret: "old")
            try vault.set(name: "github", secret: "new")
            #expect(try vault.get(name: "github") == "new")
            #expect(try vault.list() == ["github"])
        }
    }

    @Test func getMissingThrows() throws {
        try withVault { vault, _ in
            #expect(throws: FaceUnlockError.secretNotFound("nope")) {
                try vault.get(name: "nope")
            }
        }
    }

    @Test func listSorted() throws {
        try withVault { vault, _ in
            try vault.set(name: "zeta", secret: "z")
            try vault.set(name: "alpha", secret: "a")
            #expect(try vault.list() == ["alpha", "zeta"])
        }
    }

    @Test func removeSecret() throws {
        try withVault { vault, _ in
            try vault.set(name: "a", secret: "1")
            try vault.remove(name: "a")
            #expect(try vault.list().isEmpty)
            #expect(throws: (any Error).self) { try vault.remove(name: "a") }
        }
    }

    @Test func vaultEncryptedAtRest() throws {
        try withVault { vault, dataDir in
            try vault.set(name: "github", secret: "super-secret-value")
            let raw = try Data(contentsOf: FaceUnlockConfig.vaultFile(dataDir: dataDir))
            #expect(String(data: raw, encoding: .utf8)?.contains("super-secret-value") != true)
        }
    }
}

// MARK: - LivenessDetector

@Suite struct LivenessDetectorTests {
    @Test func noneModeIsImmediatelySatisfied() {
        #expect(LivenessDetector(mode: .none).isSatisfied)
    }

    @Test func turnChallenge() throws {
        let detector = LivenessDetector(mode: .turn)
        detector.activateChallenge()
        let challenge = try #require(detector.challenge)

        // Neutral pose does not satisfy.
        #expect(!detector.process(yaw: 0.0, eyeAspectRatio: 0.3))

        switch challenge {
        case .turnLeft:
            #expect(!detector.process(yaw: 0.2, eyeAspectRatio: 0.3))
            #expect(detector.process(yaw: -0.2, eyeAspectRatio: 0.3))
        case .turnRight:
            #expect(!detector.process(yaw: -0.2, eyeAspectRatio: 0.3))
            #expect(detector.process(yaw: 0.2, eyeAspectRatio: 0.3))
        case .blink:
            Issue.record("turn mode must not produce a blink challenge")
        }
        #expect(detector.isSatisfied)
    }

    @Test func blinkChallengeRequiresOpenClosedOpen() {
        let detector = LivenessDetector(mode: .blink)
        detector.activateChallenge()
        #expect(detector.challenge?.prompt == "Blink")

        // closed first (never seen open) → not satisfied
        #expect(!detector.process(yaw: 0, eyeAspectRatio: 0.10))
        // open
        #expect(!detector.process(yaw: 0, eyeAspectRatio: 0.30))
        // closed
        #expect(!detector.process(yaw: 0, eyeAspectRatio: 0.10))
        // open again → blink complete
        #expect(detector.process(yaw: 0, eyeAspectRatio: 0.30))
        #expect(detector.isSatisfied)
    }

    @Test func blinkIgnoresMissingLandmarks() {
        let detector = LivenessDetector(mode: .blink)
        detector.activateChallenge()
        #expect(!detector.process(yaw: 0, eyeAspectRatio: nil))
        #expect(!detector.isSatisfied)
    }
}

// MARK: - CLI support

@Suite struct CLIArgumentsTests {
    @Test func flagsOptionsAndPositionals() {
        let args = CLIArguments(
            ["add", "github", "--timeout", "5", "--quiet", "--liveness=blink"],
            knownFlags: ["quiet"]
        )
        #expect(args.positional == ["add", "github"])
        #expect(args.flag("quiet"))
        #expect(args.double("timeout") == 5)
        #expect(args.string("liveness") == "blink")
        #expect(args.string("missing") == nil)
        #expect(!args.flag("missing"))
    }

    @Test func exitCodeMapping() {
        #expect(FaceUnlockExitCode.from(FaceUnlockError.notEnrolled) == .notEnrolled)
        #expect(FaceUnlockExitCode.from(FaceUnlockError.enrollmentInvalid) == .notEnrolled)
        #expect(FaceUnlockExitCode.from(FaceUnlockError.cameraPermissionDenied) == .cameraError)
        #expect(FaceUnlockExitCode.from(FaceUnlockError.modelNotFound(searched: [])) == .modelMissing)
        #expect(FaceUnlockExitCode.from(FaceUnlockError.timeout) == .noMatch)
        #expect(FaceUnlockExitCode.from(NSError(domain: "x", code: 1)) == .otherError)
    }
}

// MARK: - Config

@Suite struct ConfigTests {
    @Test func dataDirectoryOverride() {
        #expect(FaceUnlockConfig.dataDirectory(override: "/tmp/custom-faceunlock").path == "/tmp/custom-faceunlock")
    }

    @Test func defaultDataDirectory() {
        // FACEUNLOCK_DATA_DIR env can legitimately override this in dev shells.
        if ProcessInfo.processInfo.environment["FACEUNLOCK_DATA_DIR"] == nil {
            #expect(FaceUnlockConfig.dataDirectory().path.hasSuffix("Application Support/faceunlock"))
        }
    }

    @Test func modelSearchPathsIncludeOverrideFirst() {
        let paths = FaceUnlockConfig.modelSearchPaths(override: "/tmp/model.mlmodelc")
        #expect(paths.first?.path == "/tmp/model.mlmodelc")
    }

    @Test func attemptLimitDefaults() {
        // The advertised contract: 2 face attempts, then password fallback.
        #expect(FaceUnlockConfig.defaultMaxAttempts == 2)
        #expect(FaceUnlockConfig.maxAttemptsCeiling >= FaceUnlockConfig.defaultMaxAttempts)
        #expect(FaceUnlockConfig.maxAttemptsCeiling <= 5)
    }
}
