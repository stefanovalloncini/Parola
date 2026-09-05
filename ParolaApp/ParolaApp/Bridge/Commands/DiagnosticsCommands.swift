import Foundation

extension ParolaAutomationServer {
    func diagnosticsCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "exportDiagnostics",
                area: .core,
                summary: "Writes the diagnostics report to the chosen save destination and returns its path.",
                kind: .async,
                handler: { _, ctx in
                    let written: URL?
                    do {
                        written = try await ctx.model.exportDiagnostics()
                    } catch {
                        throw AutomationError.internal(
                            "diagnostics export failed: \(error.localizedDescription)"
                        )
                    }
                    guard let written else {
                        throw AutomationError.precondition("no save destination was chosen")
                    }
                    return .object(["path": .string(written.path)])
                }
            ),
        ]
    }
}
