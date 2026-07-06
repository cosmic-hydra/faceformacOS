import AVFoundation
import CoreVideo
import Foundation

/// Headless camera capture for the CLI tools and the PAM helper.
///
/// This is the GUI-free counterpart of FaceGate's `CameraManager`: no
/// SwiftUI `@Published` state, no preview layer, no NSWorkspace, no display
/// brightness tricks — just an `AVCaptureSession` with a video-data output
/// that delivers `CVPixelBuffer`s to a callback on a background queue.
public final class HeadlessCamera: NSObject {
    public enum CameraError: LocalizedError {
        case permissionDenied
        case permissionTimeout
        case cameraUnavailable
        case configurationFailed

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Camera access denied — grant it in System Settings → Privacy & Security → Camera (for the terminal app running this tool)"
            case .permissionTimeout:
                return "Timed out waiting for the camera permission decision"
            case .cameraUnavailable:
                return "No camera found on this Mac"
            case .configurationFailed:
                return "Failed to configure the camera capture session"
            }
        }
    }

    /// Called with every captured frame, on `processingQueue`.
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.faceformacos.camera", qos: .userInitiated)
    private var configured = false

    /// Optional unique ID of the camera to use (`FACEUNLOCK_CAMERA_ID` env
    /// var or `--camera` flag); defaults to the built-in camera.
    public var preferredCameraID: String?

    public override init() {
        super.init()
        preferredCameraID = ProcessInfo.processInfo.environment["FACEUNLOCK_CAMERA_ID"]
    }

    // MARK: - Permission

    /// Ensure camera permission, blocking (up to `timeout`) on the system
    /// prompt when authorization is not yet determined.
    public func ensurePermission(timeout: TimeInterval = 30) throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                throw CameraError.permissionTimeout
            }
            guard granted else { throw CameraError.permissionDenied }
        case .denied, .restricted:
            throw CameraError.permissionDenied
        @unknown default:
            throw CameraError.permissionDenied
        }
    }

    // MARK: - Start / Stop

    /// Configure (once) and start the session. Throws if no camera or the
    /// session can't be built. Frames start flowing to `onFrame`.
    public func start() throws {
        if !configured {
            try configureSession()
            configured = true
        }
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    public func stop() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    /// Block until any in-flight `onFrame` callback has finished, so callers
    /// can safely read state the callback mutates. Call after `stop()`.
    public func drain() {
        processingQueue.sync {}
    }

    // MARK: - Configuration

    private func resolveCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let cameras = discovery.devices

        if let preferredID = preferredCameraID,
           let match = cameras.first(where: { $0.uniqueID == preferredID }) {
            return match
        }
        // Built-in first — for login-style auth the user faces the laptop.
        return cameras.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? cameras.first
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // 720p is plenty for detection + a 112×112 embed, and keeps Vision fast.
        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }

        guard let camera = resolveCamera() else {
            throw CameraError.cameraUnavailable
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                throw CameraError.configurationFailed
            }
            captureSession.addInput(input)
        } catch let error as CameraError {
            throw error
        } catch {
            throw CameraError.configurationFailed
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.configurationFailed
        }
        captureSession.addOutput(videoOutput)
        // No mirroring: the pipeline is orientation-agnostic (the head-turn
        // challenge is direction-agnostic), and un-mirrored frames keep the
        // yaw sign consistent with enrollment.
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HeadlessCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
