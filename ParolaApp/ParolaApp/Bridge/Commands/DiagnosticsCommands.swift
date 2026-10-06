import Foundation

extension ParolaAutomationServer {
    func diagnosticsCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "exportDiagnostics",
                area: .core,
                summary: "Writes the diagnostics report and returns its path. With `path`, writes there directly and "
                    + "opens no panel. Without it: test mode queues the destination with `queueSaveDestination`; "
                    + "outside test mode this is refused, since the bridge never opens a save panel on the user's screen.",
                kind: .async,
                args: [
                    .init(
                        name: "path", kind: .string(), required: false,
                        summary: "Absolute file path to write the report to, with no save panel; its folder must already exist."
                    ),
                ],
                handler: { args, ctx in
                    if let path = try args.optionalString("path") {
                        guard path.hasPrefix("/") else {
                            throw AutomationError.precondition("path must be absolute")
                        }
                        let destination = URL(fileURLWithPath: path)
                        var isDirectory: ObjCBool = false
                        let folder = destination.deletingLastPathComponent().path
                        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                            throw AutomationError.precondition("the folder for path does not exist")
                        }
                        do {
                            let written = try await ctx.model.exportDiagnostics(to: destination)
                            return .object(["path": .string(written.path)])
                        } catch {
                            throw AutomationError.internal("diagnostics export failed: \(error.localizedDescription)")
                        }
                    }
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("outside test mode, pass path")
                    }
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
