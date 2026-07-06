import AVFoundation
import CoreVideo
import Foundation

/// Headless camera capture for CLI / daemon use: no AppKit, no preview layer,
/// no brightness manipulation. Delivers BGRA frames via a callback on a
/// background queue. Adapted from FaceGate-Mac's CameraManager.
public final class HeadlessCamera: NSObject {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.faceformacos.camera", qos: .userInitiated)

    /// Invoked for every captured frame (on the capture queue).
    public var onFrame: ((CVPixelBuffer) -> Void)?

    /// Optional unique ID of a preferred camera device.
    private let preferredCameraID: String?

    public init(preferredCameraID: String? = nil) {
        self.preferredCameraID = preferredCameraID
        super.init()
    }

    // MARK: - Permission

    /// Synchronously ensure camera permission, prompting if undetermined.
    public static func ensurePermission() throws {
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
            semaphore.wait()
            guard granted else { throw FaceUnlockError.cameraPermissionDenied }
        case .denied, .restricted:
            throw FaceUnlockError.cameraPermissionDenied
        @unknown default:
            throw FaceUnlockError.cameraPermissionDenied
        }
    }

    // MARK: - Device discovery

    /// All available video capture devices (external first).
    public static func availableCameras() -> [AVCaptureDevice] {
        var cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        cameras.sort { $0.deviceType == .external && $1.deviceType != .external }
        return cameras
    }

    private func resolveCamera() -> AVCaptureDevice? {
        let cameras = Self.availableCameras()
        if let preferredCameraID,
           let match = cameras.first(where: { $0.uniqueID == preferredCameraID }) {
            return match
        }
        // Prefer the built-in camera for auth (predictable placement), else anything.
        return cameras.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? cameras.first
    }

    // MARK: - Lifecycle

    /// Configure and start the capture session.
    public func start() throws {
        try Self.ensurePermission()

        session.beginConfiguration()

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else {
            session.sessionPreset = .medium
        }

        guard let camera = resolveCamera() else {
            session.commitConfiguration()
            throw FaceUnlockError.cameraUnavailable
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw FaceUnlockError.cameraConfigurationFailed
            }
            session.addInput(input)
        } catch let error as FaceUnlockError {
            throw error
        } catch {
            session.commitConfiguration()
            throw FaceUnlockError.cameraConfigurationFailed
        }

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw FaceUnlockError.cameraConfigurationFailed
        }
        session.addOutput(videoOutput)

        // Mirror so "turn left" instructions feel natural, matching the GUI app.
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        session.commitConfiguration()
        session.startRunning()
    }

    /// Stop the capture session and release the camera.
    public func stop() {
        onFrame = nil
        if session.isRunning {
            session.stopRunning()
        }
    }

    deinit {
        stop()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HeadlessCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
