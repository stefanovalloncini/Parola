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
                    guard let url = await ctx.model.exportDiagnostics() else {
                        throw AutomationError.precondition("no save destination was chosen")
                    }
                    return .object(["path": .string(url.path)])
                }
            ),
        ]
    }
}
