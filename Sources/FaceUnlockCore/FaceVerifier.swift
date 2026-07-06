import CoreVideo
import Foundation

/// Options for a verification run.
public struct VerifyOptions {
    /// Account whose enrollment to verify against (nil = current user).
    public var user: String?
    public var timeout: TimeInterval = FUConstants.defaultVerifyTimeout
    public var threshold: Float = FUConstants.defaultFaceUnlockThreshold
    /// Require the 2D liveness signals (blink + micro-motion).
    public var requireLiveness = false
    /// Additionally require the head-turn challenge (implies liveness).
    public var challenge = false
    /// Override the Core ML model location (defaults to the per-user copy).
    public var modelPath: URL?
    /// Override the capture device by unique ID.
    public var cameraID: String?
    /// Matching frames needed before success.
    public var requiredMatchFrames = FUConstants.requiredMatchFrames
    /// Minimum Vision capture quality for a frame to count.
    public var minQuality: Float = FUConstants.minimumCaptureQuality
    /// Progress messages (suitable for stderr / UI status lines).
    public var onStatus: ((String) -> Void)?

    public init() {}
}

/// Result of a verification run. Maps 1:1 onto the CLI/PAM exit contract:
/// match → 0, noMatch → 1, error → 2.
public enum VerifyOutcome {
    case match(score: Float)
    case noMatch(bestScore: Float, reason: String)
    case error(String)

    public var exitCode: Int32 {
        switch self {
        case .match: return 0
        case .noMatch: return 1
        case .error: return 2
        }
    }
}

/// Runs the live verification pipeline:
/// camera → detect (single-face + quality gates) → liveness → embed → match,
/// looping frames until enough matches accumulate or the timeout expires.
///
/// `run()` blocks the calling thread (spinning its RunLoop so framework
/// callbacks stay serviced) and is intended to be called from `main`.
public final class FaceVerifier {
    private let options: VerifyOptions

    // Mutable pipeline state, touched only on the camera queue…
    private var matchFrameCount = 0
    private var bestScore: Float = -1.0
    private var sawFace = false
    private var sawMultipleFaces = false
    private var lastStatus = ""

    // …except these two, which the runloop thread polls under `stateLock`.
    private let stateLock = NSLock()
    private var finished = false
    private var succeeded = false

    public init(options: VerifyOptions) {
        self.options = options
    }

    public func run() -> VerifyOutcome {
        // 1. Load the enrollment template.
        let store = FaceStore(user: options.user)
        let enrollment: FaceEnrollment
        do {
            enrollment = try store.loadEnrollment()
        } catch {
            return .error(error.localizedDescription)
        }
        let enrolledEmbeddings = enrollment.allEmbeddings
        guard enrollment.isValid, !enrolledEmbeddings.isEmpty else {
            return .error("Enrollment exists but is invalid — re-run faceunlock-enroll")
        }

        // 2. Load the embedding model.
        let modelURL = options.modelPath ?? FUConstants.modelPath(forUser: options.user)
        let embedder: FaceEmbedder
        do {
            embedder = try FaceEmbedder(modelURL: modelURL)
        } catch {
            return .error(error.localizedDescription)
        }

        let detector = FaceDetector()
        let matcher = FaceMatcher(threshold: options.threshold)
        let livenessRequired = options.requireLiveness || options.challenge
        let liveness = LivenessDetector(mode: options.challenge ? .challenge : .passive)

        // 3. Camera.
        let camera = HeadlessCamera()
        if let id = options.cameraID { camera.preferredCameraID = id }
        do {
            try camera.ensurePermission()
        } catch {
            return .error(error.localizedDescription)
        }

        camera.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            // The camera queue is serial and drops late frames, so frames
            // process strictly one at a time.
            self.process(
                pixelBuffer: pixelBuffer,
                detector: detector,
                embedder: embedder,
                matcher: matcher,
                liveness: liveness,
                livenessRequired: livenessRequired,
                enrolledEmbeddings: enrolledEmbeddings
            )
        }

        do {
            try camera.start()
        } catch {
            return .error(error.localizedDescription)
        }
        status("Looking for your face…")

        // 4. Spin the runloop until success or deadline.
        let deadline = Date().addingTimeInterval(options.timeout)
        while Date() < deadline && !isFinished {
            let tick = Date(timeIntervalSinceNow: 0.05)
            if !RunLoop.current.run(mode: .default, before: tick) {
                // No runloop sources registered — plain sleep instead.
                Thread.sleep(until: tick)
            }
        }

        camera.onFrame = nil
        camera.stop()
        camera.drain()   // flush any in-flight frame callback before reading state

        // 5. Verdict.
        stateLock.lock()
        let didSucceed = succeeded
        stateLock.unlock()

        if didSucceed {
            return .match(score: bestScore)
        }
        if !sawFace {
            let hint = sawMultipleFaces
                ? "multiple faces in view"
                : "no usable face detected within the timeout"
            return .noMatch(bestScore: bestScore, reason: hint)
        }
        if matchFrameCount >= options.requiredMatchFrames && livenessRequired && !liveness.isSatisfied {
            return .noMatch(bestScore: bestScore, reason: "face matched but liveness checks did not pass")
        }
        return .noMatch(bestScore: bestScore, reason: "similarity below threshold \(options.threshold)")
    }

    // MARK: - Per-frame pipeline (camera queue)

    private func process(
        pixelBuffer: CVPixelBuffer,
        detector: FaceDetector,
        embedder: FaceEmbedder,
        matcher: FaceMatcher,
        liveness: LivenessDetector,
        livenessRequired: Bool,
        enrolledEmbeddings: [[Float]]
    ) {
        guard !isFinished else { return }

        let faces = detector.detectFaces(in: pixelBuffer)

        // Gate: exactly one face in frame.
        guard faces.count == 1, let face = faces.first else {
            if faces.count > 1 {
                sawMultipleFaces = true
                status("More than one face in view — make sure you're alone in frame")
            }
            return
        }

        // Gate: capture quality.
        guard face.quality >= options.minQuality else { return }
        sawFace = true

        // Liveness accumulates evidence on every good frame.
        liveness.process(face: face)

        // Embed + match.
        guard let cropped = detector.cropFace(from: pixelBuffer, observation: face.observation),
              let embedding = embedder.generateEmbedding(from: cropped)
        else { return }

        let result = matcher.match(liveEmbedding: embedding, against: enrolledEmbeddings)
        if result.bestSimilarity > bestScore {
            bestScore = result.bestSimilarity
        }
        if result.isMatch {
            matchFrameCount += 1
        }

        let matched = matchFrameCount >= options.requiredMatchFrames
        if matched && livenessRequired && !liveness.isSatisfied {
            if let instruction = liveness.pendingInstruction {
                status("Face matched — \(instruction)")
            }
            return
        }
        if matched {
            status(String(format: "Match (similarity %.2f)", bestScore))
            stateLock.lock()
            succeeded = true
            finished = true
            stateLock.unlock()
        } else if result.isMatch {
            status("Verifying…")
        }
    }

    // MARK: - Helpers

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    private func status(_ message: String) {
        guard message != lastStatus else { return }
        lastStatus = message
        options.onStatus?(message)
    }
}
