import ArgumentParser
import Foundation
import ParolaCore

@main
struct ParolaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parola",
        abstract: "Run open-source transcription models on your Mac.",
        version: Parola.version,
        subcommands: [
            Transcribe.self,
            Record.self,
            Models.self,
            Open.self,
            Burn.self,
            Bench.self,
        ],
        defaultSubcommand: Transcribe.self
    )
}
