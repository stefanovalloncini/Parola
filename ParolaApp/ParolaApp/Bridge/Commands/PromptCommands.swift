import Foundation

extension ParolaAutomationServer {
    func promptCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "listPrompts",
                area: .prompt,
                summary: "Lists all prompts (built-in and user).",
                kind: .async,
                handler: { _, ctx in
                    let prompts = await ctx.model.promptLibrary.allPrompts
                    return .array(prompts.map { p in
                        .object([
                            "id": .string(p.id.uuidString),
                            "name": .string(p.name),
                            "isBuiltIn": .bool(p.isBuiltIn),
                            "instructions": .string(p.instructions),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "runPrompt",
                area: .prompt,
                summary: "Runs a prompt by name or id against the loaded transcript.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: false, summary: "Prompt name (alternative to id)"),
                    .init(name: "id", kind: .string(), required: false, summary: "Prompt UUID (alternative to name)"),
                ],
                handler: { args, ctx in
                    let nameArg = try args.optionalString("name")
                    let idArg = try args.optionalString("id")
                    let identifier = nameArg ?? idArg
                    guard let identifier else {
                        throw AutomationError.invalidArgs(field: "name", reason: "either 'name' or 'id' is required")
                    }
                    let prompts = await ctx.model.promptLibrary.allPrompts
                    guard let prompt = prompts.first(where: { $0.name == identifier || $0.id.uuidString == identifier }) else {
                        throw AutomationError.notFound(kind: "prompt", id: identifier)
                    }
                    guard ctx.model.transcript != nil else {
                        throw AutomationError.precondition("no transcript loaded to run prompt on")
                    }
                    ctx.model.runPrompt(prompt)
                    return .object(["started": .bool(true), "prompt": .string(prompt.name)])
                }
            ),

            AutomationCommand(
                name: "getPromptOutput",
                area: .prompt,
                summary: "Returns the last prompt output, or null.",
                kind: .sync,
                handler: { _, ctx in
                    guard let out = ctx.model.promptOutput else { return .null }
                    return .object([
                        "promptName": .string(out.promptName),
                        "text": .string(out.text),
                    ])
                }
            ),
        ]
    }
}
