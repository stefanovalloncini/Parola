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
        .library(name: "ParolaDictation", targets: ["ParolaDictation"]),
        .library(name: "ScenarioKit", targets: ["ScenarioKit"]),
        .executable(name: "parola", targets: ["parola"]),
        .executable(name: "parola-mcp", targets: ["parola-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/pointfreeco/swift-clocks.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ParolaCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "ParolaDictation",
            dependencies: [
                "ParolaCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        .target(
            name: "ParolaMCP",
            dependencies: ["ParolaCore"]
        ),
        .target(
            name: "ScenarioKit",
            path: "Sources/ScenarioKit"
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
            dependencies: ["ParolaCore", "ParolaMCP"]
        ),
        .testTarget(
            name: "ParolaCoreTests",
            dependencies: [
                "ParolaCore",
                "ParolaDictation",
                "parola",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            resources: [
                .process("Resources/sample.srt"),
                .process("Resources/sample.vtt"),
                .process("Resources/sample-crlf.srt"),
                .process("Resources/transcript-v1.json"),
                .process("Resources/transcript-legacy.json"),
                .copy("Resources/tiny.parola"),
                .copy("Resources/expected"),
            ]
        ),
        .testTarget(
            name: "ParolaMCPTests",
            dependencies: ["ParolaMCP"]
        ),
        .testTarget(
            name: "ScenarioTests",
            dependencies: ["ScenarioKit"],
            path: "Tests/ScenarioTests"
        ),
    ]
)
