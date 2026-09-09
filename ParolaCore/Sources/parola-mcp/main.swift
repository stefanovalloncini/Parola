import Foundation
import ParolaCore
import ParolaMCP

// Backward-compat shim for MCP-client configs that still point at the standalone binary.
let diagnostics = DiagnosticsBootstrap(periodicFlush: true)
await StdioRunner.run(server: MCPServer(libraryStore: .shared))
diagnostics.stopPeriodicFlush()
