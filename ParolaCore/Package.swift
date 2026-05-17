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
        .executable(name: "parola-mcp", targets: ["parola-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "ParolaCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "ParolaMCP",
            dependencies: ["ParolaCore"]
        ),
        .executableTarget(
            name: "parola",
            dependencies: [
                "ParolaCore",
                "ParolaMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "parola-mcp",
            dependencies: ["ParolaMCP"]
        ),
        .testTarget(
            name: "ParolaCoreTests",
            dependencies: ["ParolaCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ParolaMCPTests",
            dependencies: ["ParolaMCP"]
        ),
    ]
)
