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
                    try ctx.require(.dictation)
                    ctx.model.startDictationFromIntent()
                    return .object(["started": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "stopDictation",
                area: .dictation,
                summary: "Stops the active dictation session. A final transcription already running is given up after 3 s.",
                kind: .mutating,
                handler: { _, ctx in
                    try ctx.require(.dictation)
                    ctx.model.stopDictationFromBridge()
                    return .object(["stopped": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "setDictationCleanupPromptID",
                area: .dictation,
                summary: "Selects the dictation cleanup prompt by id; omit or pass an empty id to disable cleanup.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: false, summary: "Prompt UUID; omit or empty to disable"),
                ],
                handler: { args, ctx in
                    let id = try args.optionalString("id") ?? ""
                    ctx.model.dictationCleanupPromptID = id
                    return .object(["promptID": .string(id)])
                }
            ),
        ]
    }
}
