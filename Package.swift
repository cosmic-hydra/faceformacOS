// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "faceformacOS",
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
        .target(
            name: "FaceUnlockCore",
            path: "Sources/FaceUnlockCore"
        ),
        .executableTarget(
            name: "faceunlock-enroll",
            dependencies: ["FaceUnlockCore"],
            path: "Sources/faceunlock-enroll"
        ),
        .executableTarget(
            name: "faceunlock-verify",
            dependencies: ["FaceUnlockCore"],
            path: "Sources/faceunlock-verify"
        ),
        .executableTarget(
            name: "faceunlock-autofill",
            dependencies: ["FaceUnlockCore"],
            path: "Sources/faceunlock-autofill"
        ),
        .testTarget(
            name: "FaceUnlockCoreTests",
            dependencies: ["FaceUnlockCore"],
            path: "Tests/FaceUnlockCoreTests"
        ),
    ]
)
