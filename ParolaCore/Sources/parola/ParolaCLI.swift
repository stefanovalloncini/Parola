import ArgumentParser
import Foundation
import ParolaCore

@main
struct ParolaCLI: AsyncParsableCommand {
    /// Resolved once per process from the app's defaults domain, so one managed
    /// config governs the app and the CLI alike.
    static let features = FeatureSet.resolveFromAppDomain()

    private static let commandsByName: [String: ParsableCommand.Type] = [
        "transcribe": Transcribe.self,
        "record": Record.self,
        "models": Models.self,
        "engines": Engines.self,
        "open": Open.self,
        "burn": Burn.self,
        "bench": Bench.self,
        "library": Library.self,
        "mcp": MCP.self,
    ]

    static let configuration = CommandConfiguration(
        commandName: "parola",
        abstract: "Run open-source transcription models on your Mac.",
        version: Parola.version,
        subcommands: CLISubcommandPolicy.visible(features: features).compactMap { commandsByName[$0] },
        defaultSubcommand: Transcribe.self
    )
}
