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
        ]
    }
}
