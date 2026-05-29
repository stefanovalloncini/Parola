import Foundation

extension ParolaAutomationServer {
    func dictationCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "startDictation",
                area: .dictation,
                summary: "Starts the dictation flow (App Intents path).",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.startDictationFromIntent()
                    return .object(["started": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "stopDictation",
                area: .dictation,
                summary: "Stops the active dictation session.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.stopDictationFromIntent()
                    return .object(["stopped": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "setDictationCleanupPromptID",
                area: .dictation,
                summary: "Selects the dictation cleanup prompt by id (empty string disables cleanup).",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Prompt UUID, or empty to disable"),
                ],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.dictationCleanupPromptID = id
                    return .object(["promptID": .string(id)])
                }
            ),
        ]
    }
}
