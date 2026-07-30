import Foundation

extension ParolaAutomationServer {
    func modelCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "selectModel",
                area: .model,
                summary: "Selects the active transcription model, with the same side effects as the toolbar picker.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: true, summary: "Model name (e.g. openai_whisper-tiny)"),
                ],
                handler: { args, ctx in
                    let name = try args.string("name")
                    ctx.model.activateModel(name)
                    return .object(["selectedModel": .string(name)])
                }
            ),

            AutomationCommand(
                name: "downloadModel",
                area: .model,
                summary: "Starts an async download of the named model.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: true, summary: "Model name to download"),
                ],
                handler: { args, ctx in
                    let name = try args.string("name")
                    ctx.model.downloadModel(name)
                    return .object(["started": .bool(true), "name": .string(name)])
                }
            ),

            AutomationCommand(
                name: "deleteModel",
                area: .model,
                summary: "Deletes the named installed model.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: true, summary: "Model name to delete"),
                ],
                handler: { args, ctx in
                    let name = try args.string("name")
                    guard name != ctx.model.selectedModel else {
                        throw AutomationError.precondition("can't delete the active model; select another model first")
                    }
                    ctx.model.deleteModel(name)
                    return .object(["deleted": .string(name)])
                }
            ),
        ]
    }
}
