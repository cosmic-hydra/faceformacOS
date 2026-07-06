import CoreGraphics
import CoreML
import Foundation

/// Generates 512-dimensional face embeddings with a Core ML MobileFaceNet model.
/// Ported from FaceGate-Mac, adapted for headless use: the model is loaded from
/// an explicit file path (not an app bundle), and the weak pixel-average
/// fallback is refused unless explicitly allowed (development only).
public final class FaceEmbedder {
    /// Output embedding dimension (InsightFace w600k MobileFaceNet).
    public static let embeddingDimension = 512

    /// Expected model input size.
    public static let inputSize = CGSize(width: 112, height: 112)

    private var mlModel: MLModel?
    private let allowWeakFallback: Bool

    /// Whether the real ML model is loaded.
    public var isModelLoaded: Bool { mlModel != nil }

    /// Load the embedder.
    /// - Parameters:
    ///   - modelPath: explicit path to `FaceEmbedding.mlmodelc` (or `.mlpackage`).
    ///     When nil, the standard search paths are consulted.
    ///   - allowWeakFallback: permit the insecure pixel-average embedder when no
    ///     model can be found. Defaults to the `FACEUNLOCK_ALLOW_WEAK=1` env flag.
    /// - Throws: `FaceUnlockError.modelNotFound` / `.modelLoadFailed` unless the
    ///   weak fallback is explicitly allowed.
    public init(modelPath: String? = nil,
                allowWeakFallback: Bool = ProcessInfo.processInfo.environment["FACEUNLOCK_ALLOW_WEAK"] == "1") throws {
        self.allowWeakFallback = allowWeakFallback

        let config = MLModelConfiguration()
        config.computeUnits = .all  // Prefer ANE, fall back to GPU/CPU.

        if let url = FaceUnlockConfig.resolveModelPath(override: modelPath) {
            do {
                if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
                    let compiledURL = try MLModel.compileModel(at: url)
                    self.mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
                } else {
                    self.mlModel = try MLModel(contentsOf: url, configuration: config)
                }
                return
            } catch {
                if !allowWeakFallback {
                    throw FaceUnlockError.modelLoadFailed(String(describing: error))
                }
            }
        } else if !allowWeakFallback {
            let searched = FaceUnlockConfig.modelSearchPaths(override: modelPath).map(\.path)
            throw FaceUnlockError.modelNotFound(searched: searched)
        }
    }

    // MARK: - Embedding Generation

    /// Generate an L2-normalized embedding from a cropped face image.
    public func generateEmbedding(from faceImage: CGImage) -> [Float]? {
        if let model = mlModel {
            return generateWithModel(model, from: faceImage)
        }
        guard allowWeakFallback else { return nil }
        return generateFallbackEmbedding(from: faceImage)
    }

    // MARK: - Model Inference

    private func generateWithModel(_ model: MLModel, from faceImage: CGImage) -> [Float]? {
        guard let resized = resizeImage(faceImage, to: Self.inputSize),
              let inputArray = imageToMultiArray(resized),
              let inputFeatureProvider = try? MLDictionaryFeatureProvider(dictionary: [
                  "face_image": MLFeatureValue(multiArray: inputArray)
              ]),
              let prediction = try? model.prediction(from: inputFeatureProvider) else { return nil }

        let embeddingMultiArray: MLMultiArray?
        if let feat = prediction.featureValue(for: "embedding")?.multiArrayValue {
            embeddingMultiArray = feat
        } else {
            let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "embedding"
            embeddingMultiArray = prediction.featureValue(for: outputName)?.multiArrayValue
        }

        guard let multiArray = embeddingMultiArray else { return nil }

        let count = multiArray.count
        var embedding = [Float](repeating: 0, count: count)
        for i in 0..<count {
            embedding[i] = Float(truncating: multiArray[i])
        }

        return VectorMath.normalize(embedding)
    }

    /// CGImage → MLMultiArray [1, 3, 112, 112], normalized to [-1, 1] (InsightFace convention).
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

        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32) else {
            return nil
        }

        // Fill in NCHW order via a raw pointer (much faster than NSNumber subscripting).
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let spatial = y * width + x
                pointer[spatial] = (Float(pixelData[pixelIndex]) - 127.5) / 127.5              // R
                pointer[width * height + spatial] = (Float(pixelData[pixelIndex + 1]) - 127.5) / 127.5  // G
                pointer[2 * width * height + spatial] = (Float(pixelData[pixelIndex + 2]) - 127.5) / 127.5  // B
            }
        }

        return array
    }

    // MARK: - Weak Fallback (development only, opt-in)

    private func generateFallbackEmbedding(from faceImage: CGImage) -> [Float]? {
        guard let resized = resizeImage(faceImage, to: Self.inputSize) else { return nil }

        let width = resized.width
        let height = resized.height
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

        context.draw(resized, in: CGRect(x: 0, y: 0, width: width, height: height))

        var embedding = [Float](repeating: 0, count: Self.embeddingDimension)
        let totalPixels = width * height
        let step = max(1, totalPixels / Self.embeddingDimension)

        for i in 0..<Self.embeddingDimension {
            let pixelIndex = (i * step) % totalPixels
            let byteIndex = pixelIndex * bytesPerPixel
            let r = Float(pixelData[byteIndex]) / 255.0
            let g = Float(pixelData[byteIndex + 1]) / 255.0
            let b = Float(pixelData[byteIndex + 2]) / 255.0
            embedding[i] = (r + g + b) / 3.0
        }

        return VectorMath.normalize(embedding)
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
