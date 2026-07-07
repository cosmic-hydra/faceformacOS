import ApplicationServices
import CoreGraphics
import Foundation

/// Types a string into the currently focused field by synthesizing keyboard
/// events (CGEvent + unicode payload). Requires Accessibility permission.
///
/// Limitation (by design of macOS): secure input fields — most notably the
/// lock-screen password box — block synthetic events entirely.
public enum AutoType {
    /// Whether the current process is trusted for Accessibility.
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission (opens System Settings).
    public static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Type `text` into the focused UI element, then optionally press Return.
    /// - Parameters:
    ///   - text: the string to type.
    ///   - pressReturn: send a Return keystroke afterwards (submits most forms).
    ///   - delay: seconds to wait before typing (gives the user time to focus the target field).
    public static func type(_ text: String, pressReturn: Bool = false, delay: TimeInterval = 0) throws {
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            throw FaceUnlockError.accessibilityPermissionDenied
        }

        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        // Send the text in chunks of ≤ 20 UTF-16 units (CGEvent payload limit).
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            var end = min(index + 20, utf16.count)
            // Never split a surrogate pair across events — the receiving app
            // inserts each event independently, and lone surrogates render as U+FFFD.
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) {
                end -= 1
            }
            let chunk = Array(utf16[index..<end])

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyUp.post(tap: .cghidEventTap)
            }

            index += chunk.count
            // Small pacing delay so the receiving app keeps up.
            usleep(8000)
        }

        if pressReturn {
            let returnKey: CGKeyCode = 36
            CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
