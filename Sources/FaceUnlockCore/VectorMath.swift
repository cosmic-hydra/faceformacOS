import Accelerate
import Foundation

/// High-performance vector math using Accelerate (vDSP).
/// Ported from FaceGate-Mac.
public enum VectorMath {
    /// Cosine similarity between two vectors: -1.0 (opposite) … 1.0 (identical).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1.0 }

        var dotProduct: Float = 0
        var magnitudeASquared: Float = 0
        var magnitudeBSquared: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &magnitudeASquared, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magnitudeBSquared, vDSP_Length(b.count))

        let magnitudeA = sqrt(magnitudeASquared)
        let magnitudeB = sqrt(magnitudeBSquared)

        guard magnitudeA > 0, magnitudeB > 0 else { return -1.0 }
        return dotProduct / (magnitudeA * magnitudeB)
    }

    /// Euclidean (L2) distance between two vectors.
    public static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }

        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))

        var sumOfSquares: Float = 0
        vDSP_svesq(diff, 1, &sumOfSquares, vDSP_Length(diff.count))
        return sqrt(sumOfSquares)
    }

    /// L2-normalize a vector to unit length. Returns the input unchanged if magnitude is zero.
    public static func normalize(_ vector: [Float]) -> [Float] {
        var magnitudeSquared: Float = 0
        vDSP_svesq(vector, 1, &magnitudeSquared, vDSP_Length(vector.count))

        let magnitude = sqrt(magnitudeSquared)
        guard magnitude > 0 else { return vector }

        var result = [Float](repeating: 0, count: vector.count)
        var divisor = magnitude
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
