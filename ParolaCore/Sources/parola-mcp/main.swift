import Foundation
import ParolaMCP

/// Backward-compat shim: ships the same stdio loop as `parola mcp`. Lets MCP-client
/// configs that point at `parola-mcp` keep working after the binary consolidation.
await StdioRunner.run()
