import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func modelCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "selectModel",
                area: .model,
                summary: "Selects the active transcription model without loading it. With warm: true it also warms an installed model, the way the model picker does; a model that isn't installed is selected without a download.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: true, summary: "Model name (e.g. openai_whisper-tiny)"),
                    .init(name: "warm", kind: .boolean, required: false, summary: "Also load an installed model into the file session, as the picker does"),
                ],
                handler: { args, ctx in
                    let name = try args.string("name")
                    if try args.optionalBool("warm") == true {
                        ctx.model.pickModel(name, isInstalled: ModelStore.shared.isInstalled(name)) { _ in }
                    } else {
                        ctx.model.activateModel(name)
                    }
                    return .object(["selectedModel": .string(name)])
                }
            ),

            AutomationCommand(
                name: "copyModelDetails",
                area: .model,
                summary: "Puts the selected model's details on the pasteboard, the way Help ▸ Copy Model Details does, and replies with the same text.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.copyModelDetails()
                    return .object(["text": .string(ctx.model.modelDetailsText())])
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
                    guard ctx.model.downloadModel(name) else {
                        throw AutomationError.precondition(
                            ctx.model.modelActionError ?? "download not started"
                        )
                    }
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
