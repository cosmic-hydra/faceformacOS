import Foundation

/// Software 2D liveness: a random challenge the subject must satisfy after the
/// face matches. Raises the bar against a static photo; see the README for the
/// honest security model (this is NOT TrueDepth-grade anti-spoofing).
public enum LivenessMode: String, CaseIterable {
    /// No liveness check (match only). Fastest, least secure.
    case none
    /// Require one blink (eye-aspect-ratio dip) while the face matches.
    case blink
    /// Require a head turn (random left/right) while the face matches.
    case turn
    /// Randomly pick blink or turn for each verification.
    case auto
}

/// Tracks the state of a liveness challenge across frames.
public final class LivenessDetector {
    public enum Challenge {
        case blink
        case turnLeft
        case turnRight

        public var prompt: String {
            switch self {
            case .blink: return "Blink"
            case .turnLeft: return "Turn your head LEFT"
            case .turnRight: return "Turn your head RIGHT"
            }
        }
    }

    /// The active challenge (assigned on first matched frame).
    public private(set) var challenge: Challenge?

    /// Whether the challenge has been satisfied.
    public private(set) var isSatisfied = false

    private let mode: LivenessMode

    // Blink state machine: must observe open → closed → open.
    private var sawOpen = false
    private var sawClosed = false

    public init(mode: LivenessMode) {
        self.mode = mode
        if mode == .none {
            isSatisfied = true
        }
    }

    /// Choose the concrete challenge (called once the face has matched).
    public func activateChallenge() {
        guard challenge == nil, mode != .none else { return }
        switch mode {
        case .blink:
            challenge = .blink
        case .turn:
            challenge = Bool.random() ? .turnLeft : .turnRight
        case .auto:
            challenge = [.blink, .turnLeft, .turnRight].randomElement()
        case .none:
            break
        }
    }

    /// Feed per-frame signals from a matched face; returns true once satisfied.
    @discardableResult
    public func process(yaw: Float, eyeAspectRatio: Float?) -> Bool {
        guard !isSatisfied else { return true }
        guard let challenge else { return false }

        switch challenge {
        case .blink:
            guard let ear = eyeAspectRatio else { return false }
            if ear >= FaceUnlockConfig.blinkOpenEAR {
                if sawOpen && sawClosed {
                    isSatisfied = true  // open → closed → open completed
                }
                sawOpen = true
            } else if ear <= FaceUnlockConfig.blinkClosedEAR, sawOpen {
                sawClosed = true
            }
        case .turnLeft:
            if yaw < -FaceUnlockConfig.turnYawThreshold { isSatisfied = true }
        case .turnRight:
            if yaw > FaceUnlockConfig.turnYawThreshold { isSatisfied = true }
        }

        return isSatisfied
    }
}
