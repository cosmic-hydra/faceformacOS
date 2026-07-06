import Foundation

/// Compares live face embeddings against enrolled reference embeddings
/// using cosine similarity. Ported from FaceGate-Mac.
public final class FaceMatcher {
    public struct MatchResult {
        public let isMatch: Bool
        public let bestSimilarity: Float
        public let threshold: Float
    }

    private var threshold: Float

    public init(threshold: Float = FaceUnlockConfig.defaultMatchThreshold) {
        self.threshold = max(0.0, min(1.0, threshold))
    }

    /// Update the matching threshold.
    public func setThreshold(_ newThreshold: Float) {
        threshold = max(0.0, min(1.0, newThreshold))
    }

    /// Match a live embedding against every enrolled embedding; best score wins.
    public func match(liveEmbedding: [Float], against enrolledEmbeddings: [[Float]]) -> MatchResult {
        guard !enrolledEmbeddings.isEmpty else {
            return MatchResult(isMatch: false, bestSimilarity: -1.0, threshold: threshold)
        }

        var bestSimilarity: Float = -1.0
        for enrolled in enrolledEmbeddings {
            let similarity = VectorMath.cosineSimilarity(liveEmbedding, enrolled)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
            }
        }

        return MatchResult(isMatch: bestSimilarity >= threshold, bestSimilarity: bestSimilarity, threshold: threshold)
    }

    /// Match against the normalized centroid of the enrolled embeddings.
    public func matchAgainstCentroid(liveEmbedding: [Float], enrolledEmbeddings: [[Float]]) -> MatchResult {
        guard let first = enrolledEmbeddings.first else {
            return MatchResult(isMatch: false, bestSimilarity: -1.0, threshold: threshold)
        }

        let dimension = first.count
        var centroid = [Float](repeating: 0, count: dimension)

        for embedding in enrolledEmbeddings where embedding.count == dimension {
            for i in 0..<dimension {
                centroid[i] += embedding[i]
            }
        }

        let count = Float(enrolledEmbeddings.count)
        for i in 0..<dimension {
            centroid[i] /= count
        }

        centroid = VectorMath.normalize(centroid)
        let similarity = VectorMath.cosineSimilarity(liveEmbedding, centroid)

        return MatchResult(isMatch: similarity >= threshold, bestSimilarity: similarity, threshold: threshold)
    }
}
