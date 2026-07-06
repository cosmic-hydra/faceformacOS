import FaceUnlockCore
import Foundation

// faceunlock-verify — match a live face against the enrolled templates.
// Exit codes: 0 match · 1 no match/timeout · 2 not enrolled · 3 camera error · 4 model missing.

let usage = """
usage: faceunlock-verify [options]

Verifies the person at the camera against the enrolled face templates.
Exits 0 on a match (with liveness), non-zero otherwise — suitable for
scripting.

options:
  --timeout <seconds>    give up after this long (default 10)
  --threshold <0..1>     cosine-similarity threshold (default 0.65)
  --liveness <mode>      none | blink | turn | auto (default auto)
  --data-dir <path>      enrollment data directory (default ~/Library/Application Support/faceunlock)
  --model <path>         path to FaceEmbedding.mlmodelc
  --camera <unique-id>   use a specific camera (see faceunlock-enroll --list-cameras)
  --quiet                no status output (for scripts)
  --json                 print a JSON result to stdout
  --help                 show this help

exit codes:
  0 face matched (and liveness passed)     3 camera unavailable/denied
  1 no match within the timeout            4 embedding model missing
  2 no enrollment found
"""

let args = CLIArguments(Array(CommandLine.arguments.dropFirst()),
                        knownFlags: ["quiet", "json", "help"])

if args.flag("help") {
    print(usage)
    exit(FaceUnlockExitCode.success.rawValue)
}

let quiet = args.flag("quiet")
let jsonOutput = args.flag("json")

var livenessMode = LivenessMode.auto
if let raw = args.string("liveness") {
    guard let mode = LivenessMode(rawValue: raw) else {
        printErr("error: invalid --liveness '\(raw)' (expected none|blink|turn|auto)")
        exit(FaceUnlockExitCode.usageError.rawValue)
    }
    livenessMode = mode
}

let options = FaceVerifier.Options(
    timeout: args.double("timeout") ?? FaceUnlockConfig.defaultVerifyTimeout,
    threshold: args.float("threshold") ?? FaceUnlockConfig.defaultMatchThreshold,
    livenessMode: livenessMode,
    modelPath: args.string("model"),
    cameraID: args.string("camera"),
    dataDir: FaceUnlockConfig.dataDirectory(override: args.string("data-dir"))
)

let verifier = FaceVerifier(options: options)

if !quiet {
    var lastStatus = ""
    verifier.onStatus = { status in
        guard status != lastStatus else { return }
        lastStatus = status
        printErr(status)
    }
}

do {
    let outcome = try verifier.verify()
    let ok = outcome.matched && outcome.livenessPassed

    if jsonOutput {
        let payload: [String: Any] = [
            "matched": outcome.matched,
            "livenessPassed": outcome.livenessPassed,
            "bestSimilarity": Double(outcome.bestSimilarity),
            "elapsedSeconds": outcome.elapsed,
            "success": ok,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(data: data, encoding: .utf8)!)
        }
    } else if !quiet {
        printErr(ok ? "✓ Face verified (similarity \(String(format: "%.3f", outcome.bestSimilarity)))"
                    : "✗ Verification failed (best similarity \(String(format: "%.3f", outcome.bestSimilarity)))")
    }

    exit(ok ? FaceUnlockExitCode.success.rawValue : FaceUnlockExitCode.noMatch.rawValue)
} catch {
    if !quiet {
        printErr("error: \(error.localizedDescription)")
    }
    exit(FaceUnlockExitCode.from(error).rawValue)
}
