// faceunlock-autofill — face-gated credential vault.
//
//   faceunlock-autofill set  --user NAME [--label L]   (secret read from stdin)
//   faceunlock-autofill get  --user NAME [--label L]   (face verify, then print)
//   faceunlock-autofill type --user NAME [--label L]   (face verify, then keystrokes)
//   faceunlock-autofill list | remove --label L
//
// Secrets are never passed on argv (visible in `ps`); `set` reads stdin.
// `get`/`type` run the full face verification (with liveness by default)
// before releasing anything.
import CoreGraphics
import FaceUnlockCore
import Foundation

let usage = """
Usage: faceunlock-autofill <set|get|type|list|remove> [options]
  set     store a secret (read from stdin — piped, or prompted without echo)
  get     verify face, then print the secret to stdout
  type    verify face, then type the secret as keystrokes (needs Accessibility)
  list    list stored labels
  remove  delete a stored secret

Options:
  --user NAME       account (default: current user)
  --label L         credential label (default: "default")
  --timeout SEC     verification timeout (default: 10)
  --threshold F     similarity threshold (default: 0.65)
  --no-liveness     skip the liveness requirement for get/type
  --challenge       require the head-turn challenge as well
  --model PATH      compiled .mlmodelc override
  --camera ID       capture device unique ID
  --quiet           suppress progress output on stderr

Exit codes: 0 = success, 1 = face verification failed, 2 = error.
"""

func fail(_ message: String) -> Never {
    printErr("faceunlock-autofill: \(message)")
    exit(2)
}

let parsed: ParsedArgs = {
    do {
        return try parseCommandLine(
            Array(CommandLine.arguments.dropFirst()),
            flagNames: ["--no-liveness", "--challenge", "--quiet", "--help"],
            optionNames: ["--user", "--label", "--timeout", "--threshold", "--model", "--camera"]
        )
    } catch {
        printErr("faceunlock-autofill: \(error)")
        printErr(usage)
        exit(2)
    }
}()

if parsed.flags.contains("--help") || parsed.positionals.isEmpty {
    printErr(usage)
    exit(parsed.flags.contains("--help") ? 0 : 2)
}

let command = parsed.positionals[0]
guard parsed.positionals.count == 1 else {
    fail("unexpected argument \(parsed.positionals[1])")
}

let user = parsed.options["--user"] ?? NSUserName()
let label = parsed.options["--label"] ?? CredentialVault.defaultLabel
let vault = CredentialVault(user: user)
let quiet = parsed.flags.contains("--quiet")

/// Run face verification with the vault's stricter defaults (liveness on
/// unless explicitly disabled). Exits the process on failure.
func requireFaceMatch() {
    var options = VerifyOptions()
    options.user = user
    options.requireLiveness = !parsed.flags.contains("--no-liveness")
    options.challenge = parsed.flags.contains("--challenge")
    options.cameraID = parsed.options["--camera"]
    if let timeoutString = parsed.options["--timeout"] {
        guard let timeout = TimeInterval(timeoutString), timeout > 0, timeout <= 300 else {
            fail("invalid --timeout \(timeoutString)")
        }
        options.timeout = timeout
    }
    if let thresholdString = parsed.options["--threshold"] {
        guard let threshold = Float(thresholdString), threshold > 0, threshold < 1 else {
            fail("invalid --threshold \(thresholdString)")
        }
        options.threshold = threshold
    }
    if let modelPathString = parsed.options["--model"] {
        options.modelPath = URL(fileURLWithPath: modelPathString)
    }
    if !quiet {
        options.onStatus = { printErr($0) }
    }

    switch FaceVerifier(options: options).run() {
    case .match(let score):
        if !quiet { printErr(String(format: "Face verified (similarity %.2f)", score)) }
    case .noMatch(_, let reason):
        printErr("faceunlock-autofill: face verification failed — \(reason)")
        exit(1)
    case .error(let message):
        fail("face verification error — \(message)")
    }
}

/// Synthesize keystrokes for `text` (Unicode-safe, chunked). Requires the
/// terminal app to have Accessibility / Input Monitoring permission.
func typeAsKeystrokes(_ text: String) {
    guard CGPreflightPostEventAccess() else {
        _ = CGRequestPostEventAccess()
        fail("""
        not allowed to synthesize keystrokes yet. Grant your terminal app
        Accessibility permission (System Settings → Privacy & Security →
        Accessibility), then retry.
        """)
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    let utf16 = Array(text.utf16)
    var index = 0
    while index < utf16.count {
        let chunk = Array(utf16[index..<min(index + 16, utf16.count)])
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            chunk.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
        usleep(8000)
        index += 16
    }
}

switch command {
case "set":
    guard let secret = readSecretLine(prompt: "Secret for \"\(label)\" (input hidden): "),
          !secret.isEmpty else {
        fail("no secret provided on stdin")
    }
    if isatty(fileno(stdin)) == 1 {
        guard let confirmation = readSecretLine(prompt: "Repeat to confirm: "),
              confirmation == secret else {
            fail("secrets did not match")
        }
    }
    do {
        try vault.set(label: label, secret: secret)
    } catch {
        fail(error.localizedDescription)
    }
    printErr("Stored secret \"\(label)\" for \(user).")

case "get":
    requireFaceMatch()
    do {
        let secret = try vault.secret(for: label)
        // No trailing newline: `faceunlock-autofill get | pbcopy` stays exact.
        FileHandle.standardOutput.write(secret.data(using: .utf8) ?? Data())
        if isatty(fileno(stdout)) == 1 { printErr("") }
    } catch {
        fail(error.localizedDescription)
    }

case "type":
    // Read the secret only after the face gate passes.
    requireFaceMatch()
    let secret: String
    do {
        secret = try vault.secret(for: label)
    } catch {
        fail(error.localizedDescription)
    }
    printErr("Typing in 3 seconds — focus the target password field…")
    Thread.sleep(forTimeInterval: 3)
    typeAsKeystrokes(secret)
    printErr("Done.")

case "list":
    do {
        for storedLabel in try vault.labels() {
            print(storedLabel)
        }
    } catch {
        fail(error.localizedDescription)
    }

case "remove":
    do {
        try vault.remove(label: label)
        printErr("Removed \"\(label)\".")
    } catch {
        fail(error.localizedDescription)
    }

default:
    printErr("faceunlock-autofill: unknown command \"\(command)\"")
    printErr(usage)
    exit(2)
}

exit(0)
