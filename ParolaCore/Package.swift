// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParolaCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ParolaCore", targets: ["ParolaCore"]),
        .executable(name: "parola", targets: ["parola"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ParolaCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "parola",
            dependencies: [
                "ParolaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ParolaCoreTests",
            dependencies: ["ParolaCore"],
            resources: [.process("Resources")]
        ),
    ]
)
