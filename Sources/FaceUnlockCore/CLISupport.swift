import Foundation

/// Minimal flag/option parser shared by the faceunlock CLIs.
/// (Deliberately tiny — avoids an external swift-argument-parser dependency
/// so the tools build with just the Command Line Tools.)
public struct CLIArguments {
    public private(set) var positional: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    /// Parse `arguments` (excluding argv[0]).
    /// `knownFlags` are boolean switches; everything else starting with `--` expects a value.
    public init(_ arguments: [String], knownFlags: Set<String>) {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if knownFlags.contains(name) {
                    flags.insert(name)
                } else if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else if index + 1 < arguments.count {
                    options[name] = arguments[index + 1]
                    index += 1
                } else {
                    options[name] = ""
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
    }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func string(_ name: String) -> String? { options[name] }

    public func double(_ name: String) -> Double? {
        options[name].flatMap(Double.init)
    }

    public func float(_ name: String) -> Float? {
        options[name].flatMap(Float.init)
    }

    public func int(_ name: String) -> Int? {
        options[name].flatMap(Int.init)
    }
}

/// Shared exit codes across the faceunlock CLIs (consumed by pam_faceunlock).
public enum FaceUnlockExitCode: Int32 {
    case success = 0
    case noMatch = 1
    case notEnrolled = 2
    case cameraError = 3
    case modelMissing = 4
    case usageError = 64   // EX_USAGE
    case otherError = 70   // EX_SOFTWARE

    /// Map a thrown error to the right exit code.
    public static func from(_ error: Error) -> FaceUnlockExitCode {
        guard let e = error as? FaceUnlockError else { return .otherError }
        switch e {
        case .notEnrolled, .enrollmentInvalid:
            return .notEnrolled
        case .cameraPermissionDenied, .cameraUnavailable, .cameraConfigurationFailed:
            return .cameraError
        case .modelNotFound, .modelLoadFailed, .weakEmbedderRefused:
            return .modelMissing
        case .timeout:
            return .noMatch
        default:
            return .otherError
        }
    }
}

/// Print to stderr.
public func printErr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Read a line from the terminal with echo disabled (for secrets).
public func readSecretLine(prompt: String) -> String? {
    printErr(prompt)

    var term = termios()
    let hasTTY = tcgetattr(STDIN_FILENO, &term) == 0
    if hasTTY {
        var noEcho = term
        noEcho.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &noEcho)
    }
    defer {
        if hasTTY {
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
        }
    }

    return readLine(strippingNewline: true)
}
