import Foundation
import ParolaCore
import ParolaMCP

// Backward-compat shim for MCP-client configs that still point at the standalone binary.
let environment = ProcessInfo.processInfo.environment
ParolaLog.install(FileDiagnosticsSink(
    directory: FileDiagnosticsSink.defaultDirectory,
    minimumLevel: environment["PAROLA_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .info
))
ParolaLog.info(.cli, "diagnostics sink installed")
await StdioRunner.run()
