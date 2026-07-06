// faceunlock-verify — headless face verification.
//
// This is the binary the PAM module execs, so its contract is frozen:
//   faceunlock-verify --user NAME --timeout SEC [--require-liveness]
//   exit 0 = match, 1 = no match, 2 = error
//   last stdout line: "RESULT match|nomatch|error score=NN"
import FaceUnlockCore
import Foundation

let usage = """
Usage: faceunlock-verify [options]
  --user NAME          account to verify against (default: current user)
  --timeout SEC        give up after SEC seconds (default: 10)
  --require-liveness   require blink + head micro-motion
  --challenge          additionally require a head-turn challenge
  --threshold F        cosine-similarity threshold 0..1 (default: 0.65)
  --model PATH         path to a compiled .mlmodelc (default: per-user copy)
  --camera ID          capture device unique ID
  --quiet              suppress progress output on stderr
  --help               show this help

Exit codes: 0 = match, 1 = no match, 2 = error.
The last stdout line is always: RESULT match|nomatch|error score=NN
"""

/// Print the machine-readable trailer and exit. `score` is the best cosine
/// similarity seen (-1 when nothing comparable was captured).
func finish(_ verdict: String, score: Float, code: Int32) -> Never {
    print(String(format: "RESULT %@ score=%.2f", verdict, score))
    exit(code)
}

let parsed: ParsedArgs = {
    do {
        return try parseCommandLine(
            Array(CommandLine.arguments.dropFirst()),
            flagNames: ["--require-liveness", "--challenge", "--quiet", "--help"],
            optionNames: ["--user", "--timeout", "--threshold", "--model", "--camera"]
        )
    } catch {
        printErr("faceunlock-verify: \(error)")
        printErr(usage)
        finish("error", score: -1, code: 2)
    }
}()

if parsed.flags.contains("--help") {
    printErr(usage)
    exit(0)
}
guard parsed.positionals.isEmpty else {
    printErr("faceunlock-verify: unexpected argument \(parsed.positionals[0])")
    finish("error", score: -1, code: 2)
}

var options = VerifyOptions()
options.user = parsed.options["--user"] ?? NSUserName()
options.requireLiveness = parsed.flags.contains("--require-liveness")
options.challenge = parsed.flags.contains("--challenge")
options.cameraID = parsed.options["--camera"]

if let timeoutString = parsed.options["--timeout"] {
    guard let timeout = TimeInterval(timeoutString), timeout > 0, timeout <= 300 else {
        printErr("faceunlock-verify: invalid --timeout \(timeoutString)")
        finish("error", score: -1, code: 2)
    }
    options.timeout = timeout
}
if let thresholdString = parsed.options["--threshold"] {
    guard let threshold = Float(thresholdString), threshold > 0, threshold < 1 else {
        printErr("faceunlock-verify: invalid --threshold \(thresholdString)")
        finish("error", score: -1, code: 2)
    }
    options.threshold = threshold
}
if let modelPathString = parsed.options["--model"] {
    options.modelPath = URL(fileURLWithPath: modelPathString)
}
if !parsed.flags.contains("--quiet") {
    options.onStatus = { printErr($0) }
}

let verifier = FaceVerifier(options: options)
switch verifier.run() {
case .match(let score):
    finish("match", score: score, code: 0)
case .noMatch(let bestScore, let reason):
    printErr("faceunlock-verify: no match — \(reason)")
    finish("nomatch", score: bestScore, code: 1)
case .error(let message):
    printErr("faceunlock-verify: error — \(message)")
    finish("error", score: -1, code: 2)
}
