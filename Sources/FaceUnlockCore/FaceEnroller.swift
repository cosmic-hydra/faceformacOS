import CoreVideo
import Foundation

/// Headless face enrollment orchestrator: guides the subject through three
/// poses (straight, left, right), collects quality-filtered embeddings, and
/// stores them encrypted. Designed for the `faceunlock-enroll` CLI.
public final class FaceEnroller {
    public struct Options {
        public var samplesPerPose: Int
        public var faceName: String
        public var modelPath: String?
        public var cameraID: String?
        public var dataDir: URL
        public var timeout: TimeInterval

        public init(samplesPerPose: Int = FaceUnlockConfig.enrollmentSamplesPerPose,
                    faceName: String = "Face 1",
                    modelPath: String? = nil,
                    cameraID: String? = nil,
                    dataDir: URL = FaceUnlockConfig.dataDirectory(),
                    timeout: TimeInterval = 120) {
            // Guard the pose-index division in enroll() against a zero/negative count.
            self.samplesPerPose = max(1, samplesPerPose)
            self.faceName = faceName
            self.modelPath = modelPath
            self.cameraID = cameraID
            self.dataDir = dataDir
            self.timeout = timeout
        }
    }

    public enum Pose: CaseIterable {
        case straight, left, right

        public var prompt: String {
            switch self {
            case .straight: return "Look straight at the camera"
            case .left: return "Turn your head slightly to the LEFT"
            case .right: return "Turn your head slightly to the RIGHT"
            }
        }
    }

    /// Status callback (pose prompts, capture progress, warnings).
    public var onStatus: ((String) -> Void)?

    private let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Run enrollment. Blocks until all samples are captured or the timeout expires.
    /// - Parameter appendToExisting: add a new face to an existing enrollment instead of replacing it.
    public func enroll(appendToExisting: Bool = false) throws {
        let embedder = try FaceEmbedder(modelPath: options.modelPath)
        let detector = FaceDetector()
        let store = EnrollmentStore(dataDir: options.dataDir)

        let camera = HeadlessCamera(preferredCameraID: options.cameraID)
        let done = DispatchSemaphore(value: 0)
        let stateQueue = DispatchQueue(label: "com.faceformacos.enroll.state")

        let targetCount = options.samplesPerPose * Pose.allCases.count
        var collected: [[Float]] = []
        var totalQuality: Float = 0
        var framesSinceLastCapture = Int.max / 2  // allow immediate first capture
        var announcedPose: Pose?
        var finished = false

        // Frames to skip between captures so the subject can adjust.
        let captureInterval = 10

        func currentPose(sampleCount: Int) -> Pose {
            let poseIndex = min(sampleCount / options.samplesPerPose, Pose.allCases.count - 1)
            return Pose.allCases[poseIndex]
        }

        camera.onFrame = { [weak camera] pixelBuffer in
            stateQueue.sync {
                guard !finished else { return }

                let pose = currentPose(sampleCount: collected.count)
                if announcedPose != pose {
                    announcedPose = pose
                    self.onStatus?(pose.prompt)
                }

                framesSinceLastCapture += 1
                guard framesSinceLastCapture >= captureInterval else { return }

                let results = detector.detectFacesWithQuality(in: pixelBuffer)

                guard results.count == 1, let result = results.first else {
                    if results.count > 1 {
                        self.onStatus?("Only one face should be visible")
                    }
                    return
                }

                guard result.quality >= FaceUnlockConfig.minimumEnrollmentQuality else {
                    self.onStatus?("Image quality too low — improve lighting or move closer")
                    return
                }

                guard let cropped = detector.cropFace(from: pixelBuffer, observation: result.face),
                      let embedding = embedder.generateEmbedding(from: cropped) else {
                    return
                }

                collected.append(embedding)
                totalQuality += result.quality
                framesSinceLastCapture = 0
                self.onStatus?("Captured \(collected.count)/\(targetCount)")

                if collected.count >= targetCount {
                    finished = true
                    camera?.onFrame = nil
                    done.signal()
                }
            }
        }

        try camera.start()
        defer { camera.stop() }

        let waitResult = done.wait(timeout: .now() + options.timeout)
        stateQueue.sync { finished = true }

        guard waitResult == .success else { throw FaceUnlockError.timeout }

        // Build and persist the enrollment.
        let newFace = FaceEnrollment.EnrolledFace(
            name: options.faceName,
            embeddings: collected,
            averageQuality: totalQuality / Float(collected.count)
        )

        var enrollment: FaceEnrollment
        if appendToExisting, let existing = try? store.load() {
            enrollment = existing
            enrollment.faces.append(newFace)
        } else {
            enrollment = FaceEnrollment(faces: [newFace])
        }

        try store.save(enrollment)
        onStatus?("Enrollment saved (\(collected.count) samples, avg quality \(String(format: "%.2f", newFace.averageQuality)))")
    }
}
