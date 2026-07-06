// faceunlock-enroll — capture face frames and write the encrypted enrollment
// template that faceunlock-verify (and therefore PAM) authenticates against.
//
//   faceunlock-enroll --user NAME --frames N [--model PATH]
import CoreVideo
import FaceUnlockCore
import Foundation

let usage = """
Usage: faceunlock-enroll [options]
  --user NAME     account to enroll (default: current user)
  --frames N      face frames to capture, 3–30 (default: 9)
  --model PATH    source .mlmodelc to install into the user's FaceUnlock dir
                  (default: use the installed copy, or ./FaceGate/ML/FaceEmbedding.mlmodelc)
  --camera ID     capture device unique ID
  --timeout SEC   give up after SEC seconds (default: 90)
  --force         replace an existing enrollment

Captures pose-diverse, quality-gated frames (look straight, then slightly to
each side), embeds each one, and stores them AES-256-GCM encrypted at
~/Library/Application Support/FaceUnlock/enrollment.encrypted
"""

func fail(_ message: String) -> Never {
    printErr("faceunlock-enroll: \(message)")
    exit(2)
}

// MARK: - Arguments

let parsed: ParsedArgs = {
    do {
        return try parseCommandLine(
            Array(CommandLine.arguments.dropFirst()),
            flagNames: ["--force", "--help"],
            optionNames: ["--user", "--frames", "--model", "--camera", "--timeout"]
        )
    } catch {
        printErr("faceunlock-enroll: \(error)")
        printErr(usage)
        exit(2)
    }
}()

if parsed.flags.contains("--help") {
    printErr(usage)
    exit(0)
}
guard parsed.positionals.isEmpty else {
    fail("unexpected argument \(parsed.positionals[0])")
}

let user = parsed.options["--user"] ?? NSUserName()
var frameTarget = FUConstants.defaultEnrollmentFrameCount
if let framesString = parsed.options["--frames"] {
    guard let n = Int(framesString), (3...30).contains(n) else {
        fail("invalid --frames \(framesString) (expected 3–30)")
    }
    frameTarget = n
}
var timeout: TimeInterval = 90
if let timeoutString = parsed.options["--timeout"] {
    guard let t = TimeInterval(timeoutString), t > 0, t <= 600 else {
        fail("invalid --timeout \(timeoutString)")
    }
    timeout = t
}

// MARK: - Model installation

// The compiled Core ML model is a *directory*; keep a per-user copy so the
// verify helper never depends on where the repo happens to live.
let installedModel = FUConstants.modelPath(forUser: user)
let repoModel = URL(fileURLWithPath: "FaceGate/ML/FaceEmbedding.mlmodelc",
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

if let sourceString = parsed.options["--model"] {
    let source = URL(fileURLWithPath: sourceString)
    guard FileManager.default.fileExists(atPath: source.path) else {
        fail("--model path not found: \(source.path)")
    }
    if FileManager.default.fileExists(atPath: installedModel.path) {
        try? FileManager.default.removeItem(at: installedModel)
    }
    do {
        try FileManager.default.copyItem(at: source, to: installedModel)
        printErr("Installed model → \(installedModel.path)")
    } catch {
        fail("could not copy model: \(error.localizedDescription)")
    }
} else if !FileManager.default.fileExists(atPath: installedModel.path) {
    guard FileManager.default.fileExists(atPath: repoModel.path) else {
        fail("""
        no Core ML model installed and none found at \(repoModel.path).
        Pass --model /path/to/FaceEmbedding.mlmodelc
        """)
    }
    do {
        try FileManager.default.copyItem(at: repoModel, to: installedModel)
        printErr("Installed model → \(installedModel.path)")
    } catch {
        fail("could not copy model: \(error.localizedDescription)")
    }
}

let embedder: FaceEmbedder = {
    do {
        return try FaceEmbedder(modelURL: installedModel)
    } catch {
        fail(error.localizedDescription)
    }
}()

// MARK: - Existing enrollment check

let store = FaceStore(user: user)
if store.hasEnrollment && !parsed.flags.contains("--force") {
    fail("an enrollment already exists for \(user) — re-run with --force to replace it")
}

// MARK: - Capture

/// Pose buckets keep the template diverse: roughly a third of the frames
/// looking straight on, a third turned slightly each way.
final class EnrollmentSession {
    struct Sample {
        let embedding: [Float]
        let quality: Float
    }

    private let detector = FaceDetector()
    private let embedder: FaceEmbedder
    private let frameTarget: Int
    private let lock = NSLock()

    private var centerSamples: [Sample] = []
    private var negativeSamples: [Sample] = []  // head turned one way
    private var positiveSamples: [Sample] = []  // head turned the other way
    private var lastCaptureTime = Date.distantPast
    private var lastPrompt = ""

    private let sideTarget: Int
    private let centerTarget: Int
    private let centerYawLimit: Float = 0.12
    private let minimumSideYaw: Float = 0.10
    private let minimumCaptureGap: TimeInterval = 0.3

    init(embedder: FaceEmbedder, frameTarget: Int) {
        self.embedder = embedder
        self.frameTarget = frameTarget
        self.sideTarget = frameTarget / 3
        self.centerTarget = frameTarget - 2 * (frameTarget / 3)
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return centerSamples.count >= centerTarget
            && negativeSamples.count >= sideTarget
            && positiveSamples.count >= sideTarget
    }

    var samples: [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return centerSamples + negativeSamples + positiveSamples
    }

    func process(pixelBuffer: CVPixelBuffer) {
        let faces = detector.detectFaces(in: pixelBuffer)
        guard faces.count == 1, let face = faces.first else {
            if faces.count > 1 { prompt("More than one face in view — please enroll alone") }
            return
        }
        guard face.quality >= FUConstants.minimumCaptureQuality else { return }

        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) >= minimumCaptureGap else {
            lock.unlock()
            return
        }

        // Which bucket does this pose belong to, and is it still needed?
        let bucket: ReferenceWritableKeyPath<EnrollmentSession, [Sample]>?
        if abs(face.yaw) <= centerYawLimit && centerSamples.count < centerTarget {
            bucket = \EnrollmentSession.centerSamples
        } else if face.yaw <= -minimumSideYaw && negativeSamples.count < sideTarget {
            bucket = \EnrollmentSession.negativeSamples
        } else if face.yaw >= minimumSideYaw && positiveSamples.count < sideTarget {
            bucket = \EnrollmentSession.positiveSamples
        } else {
            bucket = nil
        }

        guard let bucket else {
            lock.unlock()
            promptForNeededPose()
            return
        }
        lock.unlock()

        // Embedding is the slow step — do it outside the lock.
        guard let cropped = detector.cropFace(from: pixelBuffer, observation: face.observation),
              let embedding = embedder.generateEmbedding(from: cropped)
        else { return }

        lock.lock()
        self[keyPath: bucket].append(Sample(embedding: embedding, quality: face.quality))
        lastCaptureTime = now
        let captured = centerSamples.count + negativeSamples.count + positiveSamples.count
        lock.unlock()

        prompt("Captured frame \(captured)/\(frameTarget)")
        promptForNeededPose()
    }

    private func promptForNeededPose() {
        lock.lock()
        let needCenter = centerSamples.count < centerTarget
        let needNegative = negativeSamples.count < sideTarget
        let needPositive = positiveSamples.count < sideTarget
        lock.unlock()

        if needCenter {
            prompt("Look straight at the camera")
        } else if needNegative && needPositive {
            prompt("Turn your head slightly to one side")
        } else if needNegative || needPositive {
            prompt("Now turn your head slightly to the other side")
        }
    }

    private func prompt(_ message: String) {
        lock.lock()
        let repeated = message == lastPrompt
        if !repeated { lastPrompt = message }
        lock.unlock()
        if !repeated { printErr(message) }
    }
}

let camera = HeadlessCamera()
if let cameraID = parsed.options["--camera"] {
    camera.preferredCameraID = cameraID
}
do {
    try camera.ensurePermission()
} catch {
    fail(error.localizedDescription)
}

let session = EnrollmentSession(embedder: embedder, frameTarget: frameTarget)
camera.onFrame = { session.process(pixelBuffer: $0) }

do {
    try camera.start()
} catch {
    fail(error.localizedDescription)
}

printErr("Enrolling \(user): capturing \(frameTarget) frames — look straight at the camera…")

let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline && !session.isComplete {
    let tick = Date(timeIntervalSinceNow: 0.05)
    if !RunLoop.current.run(mode: .default, before: tick) {
        Thread.sleep(until: tick)
    }
}

camera.onFrame = nil
camera.stop()
camera.drain()

let samples = session.samples
guard session.isComplete else {
    fail("only captured \(samples.count)/\(frameTarget) usable frames within \(Int(timeout))s — improve lighting and retry")
}

// MARK: - Save + self-check

let averageQuality = samples.map(\.quality).reduce(0, +) / Float(samples.count)
let enrollment = FaceEnrollment(faces: [
    FaceEnrollment.EnrolledFace(
        id: UUID(),
        name: user,
        embeddings: samples.map(\.embedding),
        enrolledDate: Date(),
        averageQuality: averageQuality
    )
])

do {
    try store.saveEnrollment(enrollment)
} catch {
    fail("could not save enrollment: \(error.localizedDescription)")
}

// Sanity check: every captured embedding should sit close to the centroid.
let matcher = FaceMatcher()
var worstSimilarity: Float = 1.0
for sample in samples {
    let result = matcher.matchAgainstCentroid(
        liveEmbedding: sample.embedding,
        enrolledEmbeddings: samples.map(\.embedding)
    )
    worstSimilarity = min(worstSimilarity, result.bestSimilarity)
}

printErr(String(format: "Self-check: worst frame↔centroid similarity %.2f (threshold %.2f)",
                worstSimilarity, FUConstants.defaultFaceUnlockThreshold))
if worstSimilarity < FUConstants.defaultFaceUnlockThreshold {
    printErr("Warning: some frames are far from the centroid — consider re-enrolling in better light.")
}

print("Enrolled \(user): \(samples.count) frames, avg quality \(String(format: "%.2f", averageQuality))")
print("Template: \(FUConstants.enrollmentFilePath(forUser: user).path)")
printErr("Test it with: faceunlock-verify --user \(user) --timeout 10")
exit(0)
