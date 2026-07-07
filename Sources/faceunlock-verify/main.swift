import FaceUnlockCore
import Foundation

// faceunlock-verify — match a live face against the enrolled templates.
// Exit codes: 0 match · 1 no match/timeout · 2 not enrolled · 3 camera error · 4 model missing.

let usage = """
usage: faceunlock-verify [options]

Verifies the person at the camera against the enrolled face templates.
Exits 0 on a match (with liveness), non-zero otherwise — suitable for
scripting and for the pam_faceunlock module.

options:
  --attempts <1..5>      max attempts before giving up (default 2); each attempt
                         is a fresh camera window with a new liveness challenge
  --timeout <seconds>    give up on each attempt after this long (default 10)
  --threshold <0..1>     cosine-similarity threshold (default 0.65)
  --liveness <mode>      none | blink | turn | auto (default auto)
  --data-dir <path>      enrollment data directory (default ~/Library/Application Support/faceunlock)
  --model <path>         path to FaceEmbedding.mlmodelc
  --camera <unique-id>   use a specific camera (see faceunlock-enroll --list-cameras)
  --quiet                no status output (for PAM / scripts)
  --json                 print a JSON result to stdout
  --help                 show this help

exit codes:
  0 face matched (and liveness passed)     3 camera unavailable/denied
  1 no match within the attempt limit      4 embedding model missing
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

if let raw = args.string("attempts"), args.int("attempts") == nil {
    printErr("error: invalid --attempts '\(raw)' (expected an integer)")
    exit(FaceUnlockExitCode.usageError.rawValue)
}
let maxAttempts = max(1, min(args.int("attempts") ?? FaceUnlockConfig.defaultMaxAttempts,
                             FaceUnlockConfig.maxAttemptsCeiling))

let options = FaceVerifier.Options(
    timeout: args.double("timeout") ?? FaceUnlockConfig.defaultVerifyTimeout,
    threshold: args.float("threshold") ?? FaceUnlockConfig.defaultMatchThreshold,
    livenessMode: livenessMode,
    modelPath: args.string("model"),
    cameraID: args.string("camera"),
    dataDir: FaceUnlockConfig.dataDirectory(override: args.string("data-dir"))
)

do {
    var outcome: FaceVerifier.Outcome?
    var attemptsUsed = 0
    var bestSimilarity: Float = -1  // best across all attempts, for reporting

    for attempt in 1...maxAttempts {
        attemptsUsed = attempt
        if !quiet, maxAttempts > 1 {
            printErr("Attempt \(attempt) of \(maxAttempts)")
        }

        // Fresh verifier per attempt: new camera window, new random liveness challenge.
        let verifier = FaceVerifier(options: options)
        if !quiet {
            var lastStatus = ""
            verifier.onStatus = { status in
                guard status != lastStatus else { return }
                lastStatus = status
                printErr(status)
            }
        }

        let result = try verifier.verify()
        outcome = result
        bestSimilarity = max(bestSimilarity, result.bestSimilarity)
        if result.matched && result.livenessPassed { break }
    }

    guard let outcome else {
        exit(FaceUnlockExitCode.noMatch.rawValue)
    }
    let ok = outcome.matched && outcome.livenessPassed

    if jsonOutput {
        let payload: [String: Any] = [
            "matched": outcome.matched,
            "livenessPassed": outcome.livenessPassed,
            "bestSimilarity": Double(bestSimilarity),
            "elapsedSeconds": outcome.elapsed,
            "attempts": attemptsUsed,
            "maxAttempts": maxAttempts,
            "success": ok,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(data: data, encoding: .utf8)!)
        }
    } else if !quiet {
        printErr(ok ? "✓ Face verified (similarity \(String(format: "%.3f", bestSimilarity)), attempt \(attemptsUsed) of \(maxAttempts))"
                    : "✗ Verification failed after \(attemptsUsed) attempt(s) (best similarity \(String(format: "%.3f", bestSimilarity)))")
    }

    exit(ok ? FaceUnlockExitCode.success.rawValue : FaceUnlockExitCode.noMatch.rawValue)
} catch {
    if !quiet {
        printErr("error: \(error.localizedDescription)")
    }
    exit(FaceUnlockExitCode.from(error).rawValue)
}
