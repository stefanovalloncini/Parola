import Foundation
import Testing
@testable import ParolaCore

/// End-to-end proof that the parola binary honors the managed allowlist: the test
/// runner writes a defaults suite, spawns the real executable with the suite
/// override, and reads its output. Skips (visibly) when the binary isn't built,
/// e.g. under xcodebuild where the CLI product isn't in the products directory.
private let parolaBinaryURL: URL? = {
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("parola"))
    }
    if let main = Bundle.main.executableURL {
        var dir = main.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("parola"))
            dir.deleteLastPathComponent()
        }
    }
    let sourceFile = URL(fileURLWithPath: #filePath)
    let packageRoot = sourceFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    candidates.append(packageRoot.appendingPathComponent(".build/debug/parola"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Suite("CLI process gating", .serialized, .enabled(if: parolaBinaryURL != nil))
struct CLIProcessGateTests {
    private func runParola(_ arguments: [String], plist: String) throws -> (output: String, status: Int32) {
        let binary = try #require(parolaBinaryURL)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PAROLA_MANAGED_PLIST"] = plist
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// The managed dict travels as a plist file: cfprefsd refuses to relay defaults
    /// writes from dev-built processes, so a defaults suite can't cross to the child.
    private func withManagedPlist(_ dict: [String: Any], body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-cli-gate-\(UUID().uuidString).plist")
        try (dict as NSDictionary).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }

    @Test func gatedHelpHidesRecordAndMCP() throws {
        try withManagedPlist(["enabledFeatures": ["batch"]]) { plist in
            let result = try runParola(["--help"], plist: plist)
            let subcommands = result.output.range(of: "SUBCOMMANDS:").map { String(result.output[$0.lowerBound...]) } ?? ""
            #expect(subcommands.contains("transcribe"))
            #expect(!subcommands.contains("record "))
            #expect(!subcommands.contains("mcp "))
        }
    }

    @Test func gatedYouTubeTranscribeRefusesBeforeDownloading() throws {
        try withManagedPlist(["enabledFeatures": ["batch"]]) { plist in
            let result = try runParola(["transcribe", "https://youtu.be/x123"], plist: plist)
            #expect(result.status != 0)
            #expect(result.output.contains("disabled in this deployment"))
            #expect(!result.output.contains("Downloading"))
        }
    }

    @Test func ungatedHelpKeepsEverything() throws {
        try withManagedPlist([:]) { plist in
            let result = try runParola(["--help"], plist: plist)
            #expect(result.output.contains("record"))
            #expect(result.output.contains("mcp"))
        }
    }
}
