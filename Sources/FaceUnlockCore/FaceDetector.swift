import CoreImage
import Foundation
import Vision

/// A detected face with the signals the pipeline needs downstream.
public struct DetectedFace {
    /// Vision observation (normalized bounding box, origin bottom-left).
    public let observation: VNFaceObservation
    /// Head yaw in radians (negative = turned left in the mirrored view), 0 if unavailable.
    public let yaw: Float
    /// Eye aspect ratio (average of both eyes), or nil when landmarks are unavailable.
    /// Low values (< ~0.16) indicate closed eyes.
    public let eyeAspectRatio: Float?
}

/// Detects faces in video frames using Vision.
/// Ported from FaceGate-Mac, extended with landmark-based eye-aspect-ratio
/// extraction to support blink liveness in the headless pipeline.
public final class FaceDetector {
    public init() {}

    /// Detect faces with landmarks (for blink detection) in a pixel buffer. Synchronous.
    public func detectFaces(in pixelBuffer: CVPixelBuffer) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        return results.map { face in
            DetectedFace(
                observation: face,
                yaw: face.yaw.map { Float(truncating: $0) } ?? 0,
                eyeAspectRatio: Self.eyeAspectRatio(for: face)
            )
        }
    }

    /// Detect faces with Vision capture-quality scores — used during enrollment to filter poor frames.
    public func detectFacesWithQuality(in pixelBuffer: CVPixelBuffer) -> [(face: VNFaceObservation, quality: Float)] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, qualityRequest])
        } catch {
            return []
        }

        guard let faceResults = faceRequest.results else { return [] }
        let qualityResults = qualityRequest.results ?? []

        return faceResults.enumerated().map { index, face in
            let quality: Float
            if index < qualityResults.count, let q = qualityResults[index].faceCaptureQuality {
                quality = Float(q)
            } else {
                quality = 0.5
            }
            return (face: face, quality: quality)
        }
    }

    /// Crop the detected face from a frame with padding for better embedding quality.
    public func cropFace(from pixelBuffer: CVPixelBuffer, observation: VNFaceObservation, padding: CGFloat = 0.2) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size

        let boundingBox = observation.boundingBox
        var faceRect = CGRect(
            x: boundingBox.origin.x * imageSize.width,
            y: boundingBox.origin.y * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )

        let padX = faceRect.width * padding
        let padY = faceRect.height * padding
        faceRect = faceRect.insetBy(dx: -padX, dy: -padY)
        faceRect = faceRect.intersection(ciImage.extent)
        guard !faceRect.isEmpty else { return nil }

        let croppedCI = ciImage.cropped(to: faceRect)
        let context = CIContext()
        return context.createCGImage(croppedCI, from: croppedCI.extent)
    }

    // MARK: - Eye Aspect Ratio

    /// Average eye aspect ratio (eye height / eye width) across both eyes.
    /// Typical open-eye values are 0.25–0.35; a blink dips below ~0.16.
    static func eyeAspectRatio(for face: VNFaceObservation) -> Float? {
        guard let landmarks = face.landmarks else { return nil }

        var ratios: [Float] = []
        for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
            if let ratio = aspectRatio(of: eye.normalizedPoints) {
                ratios.append(ratio)
            }
        }

        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Float(ratios.count)
    }

    /// Height/width ratio of an eye contour given its normalized landmark points.
    private static func aspectRatio(of points: [CGPoint]) -> Float? {
        guard points.count >= 4 else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0 else { return nil }
        return Float(height / width)
    }
}
