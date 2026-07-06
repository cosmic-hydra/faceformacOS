import FaceUnlockCore
import Foundation

// faceunlock-autofill — face-gated credential vault.
// Secrets are AES-256-GCM encrypted at rest; `get`/`type` require a live face match first.

let usage = """
usage: faceunlock-autofill <command> [options]

commands:
  add <name>             store a secret (prompted, hidden input; or piped via stdin)
  get <name>             verify face, then print the secret to stdout
  type <name>            verify face, then type the secret into the focused field
  list                   list stored secret names
  remove <name>          delete a secret
  help                   show this help

options:
  --timeout <seconds>    face-verification timeout (default 10)
  --liveness <mode>      none | blink | turn | auto (default auto)
  --threshold <0..1>     match threshold (default 0.65)
  --data-dir <path>      data directory (default ~/Library/Application Support/faceunlock)
  --model <path>         path to FaceEmbedding.mlmodelc
  --camera <unique-id>   use a specific camera
  --delay <seconds>      (type) wait before typing so you can focus the field (default 3)
  --press-return         (type) press Return after typing
  --quiet                suppress status output

Secrets are released only after a live face match. `type` requires
Accessibility permission and does not work in secure input fields
(e.g. the macOS lock screen).
"""

let args = CLIArguments(Array(CommandLine.arguments.dropFirst()),
                        knownFlags: ["press-return", "quiet", "help"])

guard let command = args.positional.first, command != "help", !args.flag("help") else {
    print(usage)
    exit(FaceUnlockExitCode.success.rawValue)
}

let quiet = args.flag("quiet")
let dataDir = FaceUnlockConfig.dataDirectory(override: args.string("data-dir"))
let vault = CredentialVault(dataDir: dataDir)

/// Run face verification; exits the process on failure.
func requireFaceMatch() {
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
        dataDir: dataDir
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
        guard outcome.matched && outcome.livenessPassed else {
            printErr("✗ Face verification failed — secret not released.")
            exit(FaceUnlockExitCode.noMatch.rawValue)
        }
        if !quiet { printErr("✓ Face verified") }
    } catch {
        printErr("error: \(error.localizedDescription)")
        exit(FaceUnlockExitCode.from(error).rawValue)
    }
}

func requireName() -> String {
    guard args.positional.count >= 2 else {
        printErr("error: missing secret name\n")
        printErr(usage)
        exit(FaceUnlockExitCode.usageError.rawValue)
    }
    return args.positional[1]
}

do {
    switch command {
    case "add":
        let name = requireName()
        let secret: String
        if isatty(STDIN_FILENO) != 0 {
            guard let entered = readSecretLine(prompt: "Secret for '\(name)' (input hidden):"), !entered.isEmpty else {
                printErr("error: empty secret")
                exit(FaceUnlockExitCode.usageError.rawValue)
            }
            secret = entered
        } else {
            // Piped input: read all of stdin, trimming the trailing newline.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard var piped = String(data: data, encoding: .utf8), !piped.isEmpty else {
                printErr("error: empty secret on stdin")
                exit(FaceUnlockExitCode.usageError.rawValue)
            }
            if piped.hasSuffix("\n") { piped.removeLast() }
            secret = piped
        }
        try vault.set(name: name, secret: secret)
        printErr("✓ Stored secret '\(name)'.")

    case "get":
        let name = requireName()
        _ = try vault.get(name: name)  // fail fast before opening the camera
        requireFaceMatch()
        print(try vault.get(name: name))

    case "type":
        let name = requireName()
        _ = try vault.get(name: name)  // fail fast before opening the camera
        requireFaceMatch()
        let delay = args.double("delay") ?? 3
        if !quiet && delay > 0 {
            printErr("Typing in \(Int(delay))s — focus the target field…")
        }
        try AutoType.type(try vault.get(name: name), pressReturn: args.flag("press-return"), delay: delay)
        if !quiet { printErr("✓ Typed secret '\(name)'.") }

    case "list":
        let names = try vault.list()
        if names.isEmpty {
            printErr("Vault is empty. Add a secret with: faceunlock-autofill add <name>")
        } else {
            names.forEach { print($0) }
        }

    case "remove":
        let name = requireName()
        try vault.remove(name: name)
        printErr("✓ Removed secret '\(name)'.")

    default:
        printErr("error: unknown command '\(command)'\n")
        printErr(usage)
        exit(FaceUnlockExitCode.usageError.rawValue)
    }
    exit(FaceUnlockExitCode.success.rawValue)
} catch {
    printErr("error: \(error.localizedDescription)")
    exit(FaceUnlockExitCode.from(error).rawValue)
}
