import FaceUnlockCore
import Foundation

// faceunlock-enroll — register a face as an encrypted template set.

let usage = """
usage: faceunlock-enroll [options]

Guides you through capturing face samples (straight / left / right) and stores
them AES-256-GCM encrypted in the data directory. The encryption key lives in
your login Keychain.

options:
  --name <label>         label for this face (default "Face 1")
  --add                  add another face to an existing enrollment
  --force                replace any existing enrollment without asking
  --samples <n>          samples per pose, 1..20 (default 3, total = 3 poses × n)
  --data-dir <path>      data directory (default ~/Library/Application Support/faceunlock)
  --model <path>         path to FaceEmbedding.mlmodelc
  --camera <unique-id>   use a specific camera
  --list-cameras         list available cameras and exit
  --status               show enrollment status and exit
  --remove               delete the stored enrollment and exit
  --timeout <seconds>    give up after this long (default 120)
  --help                 show this help
"""

let args = CLIArguments(Array(CommandLine.arguments.dropFirst()),
                        knownFlags: ["add", "force", "list-cameras", "status", "remove", "help"])

if args.flag("help") {
    print(usage)
    exit(FaceUnlockExitCode.success.rawValue)
}

if args.flag("list-cameras") {
    let cameras = HeadlessCamera.availableCameras()
    if cameras.isEmpty {
        print("No cameras found.")
    } else {
        for camera in cameras {
            print("\(camera.uniqueID)  \(camera.localizedName)")
        }
    }
    exit(FaceUnlockExitCode.success.rawValue)
}

let dataDir = FaceUnlockConfig.dataDirectory(override: args.string("data-dir"))
let store = EnrollmentStore(dataDir: dataDir)

if args.flag("status") {
    if store.hasEnrollment, let enrollment = try? store.load() {
        print("Enrolled: yes (\(enrollment.faces.count) face(s))")
        for face in enrollment.faces {
            print("  • \(face.name): \(face.embeddings.count) samples, avg quality \(String(format: "%.2f", face.averageQuality)), enrolled \(face.enrolledDate)")
        }
    } else {
        print("Enrolled: no")
    }
    exit(FaceUnlockExitCode.success.rawValue)
}

if args.flag("remove") {
    do {
        try store.delete()
        print("Enrollment removed.")
        exit(FaceUnlockExitCode.success.rawValue)
    } catch {
        printErr("error: \(error.localizedDescription)")
        exit(FaceUnlockExitCode.otherError.rawValue)
    }
}

let appending = args.flag("add")

if store.hasEnrollment && !appending && !args.flag("force") {
    printErr("An enrollment already exists. Use --force to replace it or --add to enroll another face.")
    exit(FaceUnlockExitCode.usageError.rawValue)
}

if let raw = args.string("samples"), args.int("samples") == nil {
    printErr("error: invalid --samples '\(raw)' (expected an integer)")
    exit(FaceUnlockExitCode.usageError.rawValue)
}
let samplesPerPose = args.int("samples") ?? FaceUnlockConfig.enrollmentSamplesPerPose
guard (1...20).contains(samplesPerPose) else {
    printErr("error: --samples must be 1..20")
    exit(FaceUnlockExitCode.usageError.rawValue)
}

let options = FaceEnroller.Options(
    samplesPerPose: samplesPerPose,
    faceName: args.string("name") ?? "Face 1",
    modelPath: args.string("model"),
    cameraID: args.string("camera"),
    dataDir: dataDir,
    timeout: args.double("timeout") ?? 120
)

let enroller = FaceEnroller(options: options)

var lastStatus = ""
enroller.onStatus = { status in
    guard status != lastStatus else { return }
    lastStatus = status
    printErr(status)
}

printErr("Starting face enrollment — position yourself in front of the camera.")

do {
    try enroller.enroll(appendToExisting: appending)
    printErr("✓ Done. Test it with: faceunlock-verify")
    exit(FaceUnlockExitCode.success.rawValue)
} catch {
    printErr("error: \(error.localizedDescription)")
    exit(FaceUnlockExitCode.from(error).rawValue)
}
