import Foundation

/// Model representing a user's face enrollment data.
/// Ported from FaceGate; the on-disk format (including the legacy single-face
/// fallback) is kept compatible.
public struct FaceEnrollment: Codable {
    public struct EnrolledFace: Codable, Identifiable {
        public let id: UUID
        public var name: String
        public let embeddings: [[Float]]
        public let enrolledDate: Date
        public let averageQuality: Float

        public init(id: UUID, name: String, embeddings: [[Float]], enrolledDate: Date, averageQuality: Float) {
            self.id = id
            self.name = name
            self.embeddings = embeddings
            self.enrolledDate = enrolledDate
            self.averageQuality = averageQuality
        }
    }

    public var faces: [EnrolledFace]

    /// Whether the enrollment has enough embeddings to be considered valid.
    public var isValid: Bool {
        !faces.isEmpty && faces.allSatisfy { $0.embeddings.count >= 3 }
    }

    /// All embeddings across every enrolled face.
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
            // Fallback to legacy single-face format
            let embeddings = try container.decode([[Float]].self, forKey: .embeddings)
            let enrolledDate = try container.decode(Date.self, forKey: .enrolledDate)
            let averageQuality = try container.decode(Float.self, forKey: .averageQuality)

            let legacyFace = EnrolledFace(
                id: UUID(),
                name: "Face 1",
                embeddings: embeddings,
                enrolledDate: enrolledDate,
                averageQuality: averageQuality
            )
            self.faces = [legacyFace]
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
