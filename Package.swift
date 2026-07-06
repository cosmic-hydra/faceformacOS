// swift-tools-version:5.9
// faceformacOS — headless Face ID-style authentication for macOS.
// Builds with Command Line Tools only (no Xcode required):
//   swift build -c release
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FaceUnlockCore", targets: ["FaceUnlockCore"]),
        .executable(name: "faceunlock-enroll", targets: ["faceunlock-enroll"]),
        .executable(name: "faceunlock-verify", targets: ["faceunlock-verify"]),
        .executable(name: "faceunlock-autofill", targets: ["faceunlock-autofill"]),
    ],
    targets: [
        // Apple frameworks (Vision, AVFoundation, CoreML, CryptoKit, Security,
        // Accelerate) are auto-linked when imported — no linker settings needed.
        .target(name: "FaceUnlockCore"),
        .executableTarget(name: "faceunlock-enroll", dependencies: ["FaceUnlockCore"]),
        .executableTarget(name: "faceunlock-verify", dependencies: ["FaceUnlockCore"]),
        .executableTarget(name: "faceunlock-autofill", dependencies: ["FaceUnlockCore"]),
    ]
)
