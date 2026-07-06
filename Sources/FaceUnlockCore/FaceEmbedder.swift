import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// Generates face embedding vectors from cropped face images using a Core ML
/// model (MobileFaceNet / InsightFace w600k, 512-d output).
///
/// Ported from FaceGate with two deliberate changes for the headless tools:
/// - The model is loaded from a **file path** (no `Bundle.main` — these
///   binaries are bare Mach-Os, not app bundles).
/// - There is **no pixel-sampling fallback embedder**. FaceGate used one for
///   development convenience, but it is trivially spoofable; for OS
///   authentication a missing model must be a hard error.
public final class FaceEmbedder {
    /// The dimension of the output embedding vector.
    public static let embeddingDimension = FUConstants.embeddingDimension

    /// The expected input image size for the model.
    public static let inputSize = CGSize(width: 112, height: 112)

    private let mlModel: MLModel
    private let inputName: String
    private let outputName: String

    public enum EmbedderError: LocalizedError {
        case modelNotFound(String)
        case modelLoadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Core ML model not found at \(path) — run faceunlock-enroll (or scripts/install.sh) to install it"
            case .modelLoadFailed(let reason):
                return "Failed to load Core ML model: \(reason)"
            }
        }
    }

    /// Load the compiled model (`.mlmodelc`) from a file path.
    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EmbedderError.modelNotFound(modelURL.path)
        }

        let config = MLModelConfiguration()
        // Prefer the Neural Engine; falls back to GPU/CPU automatically.
        config.computeUnits = .all

        do {
            self.mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            throw EmbedderError.modelLoadFailed(String(describing: error))
        }

        // FaceGate's model uses "face_image" → "embedding"; fall back to the
        // model's own declared names so other 112×112 embedders drop in.
        let desc = mlModel.modelDescription
        if desc.inputDescriptionsByName["face_image"] != nil {
            self.inputName = "face_image"
        } else {
            self.inputName = desc.inputDescriptionsByName.keys.first ?? "face_image"
        }
        if desc.outputDescriptionsByName["embedding"] != nil {
            self.outputName = "embedding"
        } else {
            self.outputName = desc.outputDescriptionsByName.keys.first ?? "embedding"
        }
    }

    // MARK: - Embedding Generation

    /// Generate an L2-normalized embedding from a cropped face image.
    public func generateEmbedding(from faceImage: CGImage) -> [Float]? {
        guard let resized = resizeImage(faceImage, to: Self.inputSize) else { return nil }
        guard let inputArray = imageToMultiArray(resized) else { return nil }

        guard let inputFeatureProvider = try? MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: inputArray)
        ]) else { return nil }

        guard let prediction = try? mlModel.prediction(from: inputFeatureProvider) else { return nil }

        guard let multiArray = prediction.featureValue(for: outputName)?.multiArrayValue else {
            return nil
        }

        let count = multiArray.count
        var embedding = [Float](repeating: 0, count: count)
        for i in 0..<count {
            embedding[i] = Float(truncating: multiArray[i])
        }

        // L2 normalize for cosine similarity.
        return VectorMath.normalize(embedding)
    }

    // MARK: - Tensor conversion

    /// Convert a CGImage to an MLMultiArray in NCHW format [1, 3, 112, 112],
    /// normalizing pixels from [0, 255] to [-1, 1] (InsightFace convention).
    private func imageToMultiArray(_ image: CGImage) -> MLMultiArray? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        ) else { return nil }

        // Write directly into the backing buffer — the NSNumber-subscript path
        // is painfully slow for 3×112×112 writes per frame.
        let plane = width * height
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * plane)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let spatial = y * width + x
                pointer[spatial] = (Float(pixelData[pixelIndex]) - 127.5) / 127.5            // R
                pointer[plane + spatial] = (Float(pixelData[pixelIndex + 1]) - 127.5) / 127.5 // G
                pointer[2 * plane + spatial] = (Float(pixelData[pixelIndex + 2]) - 127.5) / 127.5 // B
            }
        }

        return array
    }

    // MARK: - Image Utilities

    private func resizeImage(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context?.makeImage()
    }
}
