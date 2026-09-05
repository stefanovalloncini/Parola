import Foundation
import Testing
@testable import ParolaCore

@Suite("CLI process gating", .serialized, .enabled(if: parolaBinaryURL != nil))
struct CLIProcessGateTests {
    private func runParola(_ arguments: [String], plist: String) throws -> (output: String, status: Int32) {
        let run = try ParolaCoreTests.runParola(arguments, environment: ["PAROLA_MANAGED_PLIST": plist])
        return (run.output, run.status)
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
