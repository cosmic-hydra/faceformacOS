import Foundation

/// A user's face enrollment: one or more enrolled faces, each with several
/// reference embeddings captured across poses.
/// Wire-compatible with FaceGate-Mac's format (including its legacy single-face layout).
public struct FaceEnrollment: Codable {
    public struct EnrolledFace: Codable, Identifiable {
        public let id: UUID
        public var name: String
        public let embeddings: [[Float]]
        public let enrolledDate: Date
        public let averageQuality: Float

        public init(id: UUID = UUID(), name: String, embeddings: [[Float]], enrolledDate: Date = Date(), averageQuality: Float) {
            self.id = id
            self.name = name
            self.embeddings = embeddings
            self.enrolledDate = enrolledDate
            self.averageQuality = averageQuality
        }
    }

    public var faces: [EnrolledFace]

    /// Valid when every face has at least 3 reference embeddings.
    public var isValid: Bool {
        !faces.isEmpty && faces.allSatisfy { $0.embeddings.count >= 3 }
    }

    /// All embeddings across all enrolled faces, flattened for matching.
    public var allEmbeddings: [[Float]] {
        faces.flatMap { $0.embeddings }
    }

    public init(faces: [EnrolledFace]) {
        self.faces = faces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedFaces = try? container.decode([EnrolledFace].self, forKey: .faces) {
            self.faces = decodedFaces
        } else {
            // Legacy single-face format from early FaceGate versions.
            let embeddings = try container.decode([[Float]].self, forKey: .embeddings)
            let enrolledDate = try container.decode(Date.self, forKey: .enrolledDate)
            let averageQuality = try container.decode(Float.self, forKey: .averageQuality)
            self.faces = [EnrolledFace(
                name: "Face 1",
                embeddings: embeddings,
                enrolledDate: enrolledDate,
                averageQuality: averageQuality
            )]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(faces, forKey: .faces)
    }

    enum CodingKeys: String, CodingKey {
        case faces
        case embeddings
        case enrolledDate
        case averageQuality
    }
}
