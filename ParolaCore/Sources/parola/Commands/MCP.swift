import ArgumentParser
import Foundation
import ParolaMCP

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the Model Context Protocol stdio server."
    )

    func run() async throws {
        CLIDiagnostics.installIfWanted(alwaysOn: true)
        await StdioRunner.run()
        await CLIDiagnostics.flush()
    }
}
