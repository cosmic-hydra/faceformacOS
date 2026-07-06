import Foundation

/// Tiny argument parser shared by the three CLIs (no external dependencies —
/// the package must build offline with Command Line Tools only).
public struct ParsedArgs {
    public var flags: Set<String> = []
    public var options: [String: String] = [:]
    public var positionals: [String] = []

    public init() {}
}

public enum ArgParseError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .missingValue(let name): return "missing value for \(name)"
        case .unknownArgument(let name): return "unknown argument \(name)"
        }
    }
}

/// Parse `argv` (without the program name) into flags (`--foo`), options
/// (`--foo value`) and positionals. Unknown `--` arguments are an error.
public func parseCommandLine(
    _ argv: [String],
    flagNames: Set<String>,
    optionNames: Set<String>
) throws -> ParsedArgs {
    var parsed = ParsedArgs()
    var index = 0
    while index < argv.count {
        let arg = argv[index]
        if flagNames.contains(arg) {
            parsed.flags.insert(arg)
        } else if optionNames.contains(arg) {
            guard index + 1 < argv.count else {
                throw ArgParseError.missingValue(arg)
            }
            index += 1
            parsed.options[arg] = argv[index]
        } else if arg.hasPrefix("-") {
            throw ArgParseError.unknownArgument(arg)
        } else {
            parsed.positionals.append(arg)
        }
        index += 1
    }
    return parsed
}

/// Write a line to stderr (stdout is reserved for machine-readable output —
/// the PAM module parses the CLI's last stdout line).
public func printErr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
}

/// Read a secret from stdin. When stdin is a TTY, disables echo for the read.
public func readSecretLine(prompt: String) -> String? {
    let fd = fileno(stdin)
    guard isatty(fd) == 1 else {
        return readLine(strippingNewline: true)
    }

    FileHandle.standardError.write(prompt.data(using: .utf8) ?? Data())

    var original = termios()
    tcgetattr(fd, &original)
    var noEcho = original
    noEcho.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(fd, TCSANOW, &noEcho)
    defer {
        var restore = original
        tcsetattr(fd, TCSANOW, &restore)
        FileHandle.standardError.write("\n".data(using: .utf8) ?? Data())
    }

    return readLine(strippingNewline: true)
}
