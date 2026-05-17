import ArgumentParser
import Foundation
import ParolaMCP

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the Model Context Protocol stdio server."
    )

    func run() async throws {
        await StdioRunner.run()
    }
}
