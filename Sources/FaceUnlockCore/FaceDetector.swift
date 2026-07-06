import CoreImage
import Foundation
import Vision

/// A face found in a frame, with everything downstream stages need:
/// bounding box, capture quality, 2D landmarks (for blink detection), and
/// head pose (for the head-turn challenge and enrollment pose diversity).
public struct DetectedFace {
    public let observation: VNFaceObservation
    /// Vision capture-quality score, 0–1 (0.5 when unavailable).
    public let quality: Float
    /// Landmarks (eyes, nose, …) in normalized coordinates, if resolved.
    public let landmarks: VNFaceLandmarks2D?
    /// Head yaw in radians (negative/positive = turned to either side).
    public let yaw: Float
    /// Head pitch in radians.
    public let pitch: Float
    /// Head roll in radians.
    public let roll: Float

    public var boundingBox: CGRect { observation.boundingBox }
}

/// Detects faces in video frames using Apple's Vision framework.
/// Ported from FaceGate and extended: one synchronous call now returns
/// landmarks + head pose + quality, which the liveness detector consumes.
public final class FaceDetector {
    public init() {}

    /// Detect faces (with landmarks, pose and quality) in a pixel buffer.
    /// Synchronous — call from a background queue.
    public func detectFaces(in pixelBuffer: CVPixelBuffer) -> [DetectedFace] {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([landmarksRequest, qualityRequest])
        } catch {
            return []
        }

        guard let faceResults = landmarksRequest.results, !faceResults.isEmpty else {
            return []
        }
        let qualityResults = qualityRequest.results ?? []

        return faceResults.enumerated().map { index, face in
            let quality: Float
            if index < qualityResults.count, let q = qualityResults[index].faceCaptureQuality {
                quality = Float(q)
            } else {
                quality = 0.5
            }

            // Prefer Vision's pose estimates; fall back to a geometric
            // estimate from landmarks when Vision doesn't populate them.
            let yaw = face.yaw.map { Float(truncating: $0) }
                ?? Self.estimateYaw(from: face.landmarks)
            let pitch = face.pitch.map { Float(truncating: $0) }
                ?? Self.estimatePitch(from: face.landmarks)
            let roll = face.roll.map { Float(truncating: $0) } ?? 0

            return DetectedFace(
                observation: face,
                quality: quality,
                landmarks: face.landmarks,
                yaw: yaw,
                pitch: pitch,
                roll: roll
            )
        }
    }

    /// Crop the detected face region from a pixel buffer, with padding for
    /// better embedding quality. (Ported unchanged from FaceGate.)
    public func cropFace(from pixelBuffer: CVPixelBuffer, observation: VNFaceObservation, padding: CGFloat = 0.2) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size

        // Convert normalized Vision coordinates (0–1, origin bottom-left) to pixels.
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

    // MARK: - Geometric pose fallback

    /// Rough yaw estimate from the horizontal offset of the nose relative to
    /// the midpoint of the eyes. Only used when Vision omits `yaw`.
    static func estimateYaw(from landmarks: VNFaceLandmarks2D?) -> Float {
        guard let landmarks,
              let leftEye = landmarks.leftEye?.normalizedPoints, !leftEye.isEmpty,
              let rightEye = landmarks.rightEye?.normalizedPoints, !rightEye.isEmpty,
              let nosePoints = (landmarks.noseCrest ?? landmarks.nose)?.normalizedPoints,
              !nosePoints.isEmpty
        else { return 0 }

        let leftCenter = Self.centroid(of: leftEye)
        let rightCenter = Self.centroid(of: rightEye)
        let noseCenter = Self.centroid(of: nosePoints)

        let eyeMidX = (leftCenter.x + rightCenter.x) / 2
        let eyeSpan = abs(rightCenter.x - leftCenter.x)
        guard eyeSpan > 0.001 else { return 0 }

        // Nose offset as a fraction of the inter-eye span, scaled to a
        // radian-ish range. Sign convention matches "offset to one side".
        let offset = Float((noseCenter.x - eyeMidX) / eyeSpan)
        return offset * 1.2
    }

    /// Rough pitch estimate from the vertical position of the nose between
    /// the eyes and the outline bottom. Only used when Vision omits `pitch`.
    static func estimatePitch(from landmarks: VNFaceLandmarks2D?) -> Float {
        guard let landmarks,
              let leftEye = landmarks.leftEye?.normalizedPoints, !leftEye.isEmpty,
              let rightEye = landmarks.rightEye?.normalizedPoints, !rightEye.isEmpty,
              let nosePoints = (landmarks.noseCrest ?? landmarks.nose)?.normalizedPoints,
              !nosePoints.isEmpty
        else { return 0 }

        let eyeMidY = (Self.centroid(of: leftEye).y + Self.centroid(of: rightEye).y) / 2
        let noseY = Self.centroid(of: nosePoints).y

        // Neutral head pose puts the nose a fairly stable distance below the
        // eyes (in normalized face space). Deviations approximate pitch.
        let neutralDrop: CGFloat = 0.25
        let drop = eyeMidY - noseY
        return Float((drop - neutralDrop) * 2.0)
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for p in points {
            sumX += p.x
            sumY += p.y
        }
        let n = CGFloat(points.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }
}
