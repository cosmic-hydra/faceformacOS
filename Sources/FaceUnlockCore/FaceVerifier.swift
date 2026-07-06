import CoreVideo
import Foundation

/// Headless face verification orchestrator:
/// camera → detect → embed → match → liveness, within a timeout.
/// Runs synchronously (designed for CLIs and scripting).
public final class FaceVerifier {
    public struct Options {
        public var timeout: TimeInterval
        public var threshold: Float
        public var livenessMode: LivenessMode
        public var modelPath: String?
        public var cameraID: String?
        public var dataDir: URL

        public init(timeout: TimeInterval = FaceUnlockConfig.defaultVerifyTimeout,
                    threshold: Float = FaceUnlockConfig.defaultMatchThreshold,
                    livenessMode: LivenessMode = .auto,
                    modelPath: String? = nil,
                    cameraID: String? = nil,
                    dataDir: URL = FaceUnlockConfig.dataDirectory()) {
            self.timeout = timeout
            self.threshold = threshold
            self.livenessMode = livenessMode
            self.modelPath = modelPath
            self.cameraID = cameraID
            self.dataDir = dataDir
        }
    }

    public struct Outcome {
        public let matched: Bool
        public let bestSimilarity: Float
        public let livenessPassed: Bool
        public let elapsed: TimeInterval
    }

    /// Progress callback: human-readable status updates ("Looking for your face…", challenge prompts).
    public var onStatus: ((String) -> Void)?

    private let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Run verification. Blocks until match+liveness succeed or the timeout expires.
    /// - Throws: setup errors (`notEnrolled`, `modelNotFound`, camera errors).
    /// - Returns: the outcome; `matched && livenessPassed` means authentication succeeded.
    public func verify() throws -> Outcome {
        // 1. Load enrollment.
        let store = EnrollmentStore(dataDir: options.dataDir)
        let enrollment = try store.load()
        guard enrollment.isValid else { throw FaceUnlockError.enrollmentInvalid }
        let enrolledEmbeddings = enrollment.allEmbeddings

        // 2. Load model (throws when missing, unless weak fallback is explicitly allowed).
        let embedder = try FaceEmbedder(modelPath: options.modelPath)

        // 3. Set up pipeline.
        let detector = FaceDetector()
        let matcher = FaceMatcher(threshold: options.threshold)
        let liveness = LivenessDetector(mode: options.livenessMode)

        let camera = HeadlessCamera(preferredCameraID: options.cameraID)
        let done = DispatchSemaphore(value: 0)
        let stateQueue = DispatchQueue(label: "com.faceformacos.verify.state")

        var bestSimilarity: Float = -1
        var consecutiveMatches = 0
        var finished = false
        var frameCounter = 0
        let start = Date()

        // Process every Nth frame for performance (matches FaceGate's cadence).
        let processEveryNFrames = 3

        camera.onFrame = { [weak camera] pixelBuffer in
            stateQueue.sync {
                guard !finished else { return }
                frameCounter += 1
                guard frameCounter % processEveryNFrames == 0 else { return }

                let faces = detector.detectFaces(in: pixelBuffer)

                // Exactly one face for security.
                guard faces.count == 1, let face = faces.first else {
                    if faces.count > 1 {
                        self.onStatus?("Only one face allowed")
                    } else {
                        self.onStatus?("Looking for your face…")
                    }
                    consecutiveMatches = 0
                    return
                }

                guard let cropped = detector.cropFace(from: pixelBuffer, observation: face.observation),
                      let liveEmbedding = embedder.generateEmbedding(from: cropped) else {
                    return
                }

                let result = matcher.match(liveEmbedding: liveEmbedding, against: enrolledEmbeddings)
                bestSimilarity = max(bestSimilarity, result.bestSimilarity)

                guard result.isMatch else {
                    consecutiveMatches = 0
                    self.onStatus?("Face not recognized yet…")
                    return
                }

                consecutiveMatches += 1
                guard consecutiveMatches >= FaceUnlockConfig.requiredConsecutiveMatches else { return }

                // Face matches — run the liveness challenge.
                if liveness.challenge == nil, self.options.livenessMode != .none {
                    liveness.activateChallenge()
                    if let prompt = liveness.challenge?.prompt {
                        self.onStatus?("Liveness check: \(prompt)")
                    }
                }

                if liveness.process(yaw: face.yaw, eyeAspectRatio: face.eyeAspectRatio) {
                    finished = true
                    camera?.onFrame = nil
                    done.signal()
                }
            }
        }

        try camera.start()
        defer { camera.stop() }
        onStatus?("Looking for your face…")

        let waitResult = done.wait(timeout: .now() + options.timeout)
        let elapsed = Date().timeIntervalSince(start)

        var sawMatch = false
        var livenessOK = false
        var similarity: Float = -1
        stateQueue.sync {
            finished = true
            sawMatch = consecutiveMatches >= FaceUnlockConfig.requiredConsecutiveMatches
            livenessOK = liveness.isSatisfied
            similarity = bestSimilarity
        }

        if waitResult == .success {
            return Outcome(matched: true, bestSimilarity: similarity, livenessPassed: true, elapsed: elapsed)
        }
        return Outcome(matched: sawMatch, bestSimilarity: similarity, livenessPassed: livenessOK, elapsed: elapsed)
    }
}
