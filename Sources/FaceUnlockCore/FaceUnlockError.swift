import Foundation

/// Errors thrown by the FaceUnlockCore pipeline.
public enum FaceUnlockError: Error, LocalizedError, Equatable {
    case cameraPermissionDenied
    case cameraUnavailable
    case cameraConfigurationFailed
    case modelNotFound(searched: [String])
    case modelLoadFailed(String)
    case weakEmbedderRefused
    case notEnrolled
    case enrollmentInvalid
    case encryptionFailed
    case decryptionFailed
    case keychainError(OSStatus)
    case secretNotFound(String)
    case accessibilityPermissionDenied
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera permission was denied. Grant access in System Settings → Privacy & Security → Camera."
        case .cameraUnavailable:
            return "No camera is available on this system."
        case .cameraConfigurationFailed:
            return "Failed to configure the camera capture session."
        case .modelNotFound(let searched):
            return "Core ML face-embedding model not found. Searched: \(searched.joined(separator: ", "))"
        case .modelLoadFailed(let reason):
            return "Failed to load the Core ML model: \(reason)"
        case .weakEmbedderRefused:
            return "Refusing to run without the real face-recognition model (set FACEUNLOCK_ALLOW_WEAK=1 to override for development only)."
        case .notEnrolled:
            return "No face enrollment found. Run `faceunlock-enroll` first."
        case .enrollmentInvalid:
            return "Stored face enrollment is invalid or corrupt. Re-enroll with `faceunlock-enroll --force`."
        case .encryptionFailed:
            return "Failed to encrypt data."
        case .decryptionFailed:
            return "Failed to decrypt data."
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        case .secretNotFound(let name):
            return "No secret named '\(name)' in the vault."
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to type secrets. Grant access in System Settings → Privacy & Security → Accessibility."
        case .timeout:
            return "Operation timed out."
        case .cancelled:
            return "Operation was cancelled."
        }
    }
}
