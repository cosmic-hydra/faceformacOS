import CoreGraphics
import Foundation
import Vision

/// Software 2D liveness detection ("TrueDepth-style" checks without depth
/// hardware). Feed it every `DetectedFace` the verifier processes; it
/// accumulates evidence that the face is a live person rather than a photo:
///
/// - **Blink detection** — eye-aspect-ratio (EAR) from Vision eye landmarks.
///   A blink is a dip below a fraction of the observed open-eye baseline
///   followed by re-opening. Photos never blink.
/// - **Head micro-motion** — a real head jitters and rotates slightly; the
///   yaw/pitch/position ranges of a photo held on a stick are tiny only if
///   perfectly rigid, and zero for a screen on a stand.
/// - **Head-turn challenge** (optional, `.challenge` mode) — the user must
///   turn their head clearly to one side and back to center. Defeats flat
///   photos, which cannot produce a consistent pose sweep.
///
/// Honest limitation: this raises the bar against printed/displayed photos.
/// It does NOT defeat a replayed video of the owner; only depth hardware can.
public final class LivenessDetector {
    public enum Mode {
        /// Blink + head micro-motion.
        case passive
        /// Passive requirements plus an explicit head-turn-and-return sweep.
        case challenge
    }

    public struct Config {
        /// Eye openness must dip below `baseline * blinkCloseFraction`…
        public var blinkCloseFraction: Float = 0.55
        /// …then recover above `baseline * blinkReopenFraction` to count.
        public var blinkReopenFraction: Float = 0.80
        /// Frames used to establish the open-eye baseline.
        public var baselineFrameCount: Int = 5
        /// Minimum total yaw+pitch range (radians) counting as micro-motion.
        public var microMotionMinRange: Float = 0.02
        /// Yaw excursion (radians, ~14°) required by the head-turn challenge.
        public var challengeYawExcursion: Float = 0.25
        /// |yaw| below this counts as "back at center" for the challenge.
        public var challengeCenterYaw: Float = 0.10

        public init() {}
    }

    public let mode: Mode
    private let config: Config

    // Blink state
    private var opennessSamples: [Float] = []
    private var baselineOpenness: Float?
    private var eyesClosed = false
    public private(set) var blinkCount = 0

    // Motion state
    private var minYaw: Float = .greatestFiniteMagnitude
    private var maxYaw: Float = -.greatestFiniteMagnitude
    private var minPitch: Float = .greatestFiniteMagnitude
    private var maxPitch: Float = -.greatestFiniteMagnitude

    // Challenge state machine: center → excursion (either side) → back to center.
    private enum ChallengePhase { case waitingForTurn, turned, completed }
    private var challengePhase: ChallengePhase = .waitingForTurn
    public private(set) var framesProcessed = 0

    public init(mode: Mode = .passive, config: Config = Config()) {
        self.mode = mode
        self.config = config
    }

    // MARK: - Frame ingestion

    /// Process one detected face. Call only for frames that already passed
    /// the single-face and quality gates.
    public func process(face: DetectedFace) {
        framesProcessed += 1
        updateBlink(face: face)
        updateMotion(face: face)
        if mode == .challenge {
            updateChallenge(face: face)
        }
    }

    // MARK: - Verdict

    public var hasBlink: Bool { blinkCount > 0 }

    public var hasMicroMotion: Bool {
        guard maxYaw > minYaw, maxPitch > minPitch else { return false }
        return (maxYaw - minYaw) + (maxPitch - minPitch) >= config.microMotionMinRange
    }

    public var challengeCompleted: Bool { challengePhase == .completed }

    /// True once every signal required by the mode has been observed.
    public var isSatisfied: Bool {
        let passiveOK = hasBlink && hasMicroMotion
        switch mode {
        case .passive: return passiveOK
        case .challenge: return passiveOK && challengeCompleted
        }
    }

    /// Human-readable hint for what is still missing (drives CLI prompts).
    public var pendingInstruction: String? {
        if !hasBlink { return "Blink naturally" }
        if mode == .challenge && !challengeCompleted {
            switch challengePhase {
            case .waitingForTurn: return "Turn your head to one side"
            case .turned: return "Now look back at the camera"
            case .completed: break
            }
        }
        if !hasMicroMotion { return "Move your head slightly — a photo can't" }
        return nil
    }

    // MARK: - Blink (EAR)

    private func updateBlink(face: DetectedFace) {
        guard let openness = Self.eyeOpenness(landmarks: face.landmarks) else { return }

        // Establish the open-eye baseline from the first frames. Median makes
        // it robust to a blink happening during the baseline window.
        if baselineOpenness == nil {
            opennessSamples.append(openness)
            if opennessSamples.count >= config.baselineFrameCount {
                let sorted = opennessSamples.sorted()
                baselineOpenness = sorted[sorted.count / 2]
            }
            return
        }

        guard let baseline = baselineOpenness, baseline > 0.01 else { return }

        if !eyesClosed {
            if openness < baseline * config.blinkCloseFraction {
                eyesClosed = true
            } else if openness > baseline {
                // Track a slowly-improving baseline (lighting changes, etc.).
                baselineOpenness = baseline * 0.9 + openness * 0.1
            }
        } else {
            if openness > baseline * config.blinkReopenFraction {
                eyesClosed = false
                blinkCount += 1
            }
        }
    }

    /// Mean eye-aspect-ratio across both eyes: bounding-box height/width of
    /// each eye's landmark cloud. Open eyes ≈ 0.25–0.4; closed ≈ 0.05–0.15.
    static func eyeOpenness(landmarks: VNFaceLandmarks2D?) -> Float? {
        guard let landmarks else { return nil }
        var ratios: [Float] = []
        for region in [landmarks.leftEye, landmarks.rightEye] {
            guard let points = region?.normalizedPoints, points.count >= 4 else { continue }
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let width = maxX - minX
            guard width > 0.001 else { continue }
            ratios.append(Float((maxY - minY) / width))
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Float(ratios.count)
    }

    // MARK: - Micro-motion

    private func updateMotion(face: DetectedFace) {
        minYaw = min(minYaw, face.yaw)
        maxYaw = max(maxYaw, face.yaw)
        minPitch = min(minPitch, face.pitch)
        maxPitch = max(maxPitch, face.pitch)
    }

    // MARK: - Head-turn challenge

    private func updateChallenge(face: DetectedFace) {
        switch challengePhase {
        case .waitingForTurn:
            if abs(face.yaw) >= config.challengeYawExcursion {
                challengePhase = .turned
            }
        case .turned:
            if abs(face.yaw) <= config.challengeCenterYaw {
                challengePhase = .completed
            }
        case .completed:
            break
        }
    }
}
