import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func aiCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "setAIServices",
                area: .settings,
                summary: "Replaces the configured AI services with an array of {id, kind, name, endpoint, model} rows. In test mode a row may carry an apiKey, which goes to the in-memory key store. Replies {aiServices} without any key.",
                kind: .mutating,
                args: [
                    .init(name: "services", kind: .any, required: true, summary: "Array of AI service rows"),
                ],
                handler: { args, ctx in
                    guard case .array(let raw)? = args.rawValue("services") else {
                        throw AutomationError.invalidArgs(field: "services", reason: "must be an array of services")
                    }
                    let objects = raw.map { $0.jsonObject }
                    guard let data = try? JSONSerialization.data(withJSONObject: objects),
                          let decoded = try? JSONDecoder().decode([AIServiceConfig].self, from: data) else {
                        throw AutomationError.invalidArgs(field: "services", reason: "could not decode the given services")
                    }
                    ctx.model.setAIServices(decoded)
                    try await Self.storeTestKeys(from: raw, services: decoded, model: ctx.model)
                    return .object(["aiServices": ParolaAutomationServer.aiServicesState(ctx.model)])
                }
            ),

            AutomationCommand(
                name: "setLanguageModelSelection",
                area: .settings,
                summary: "Replaces the per-task model selection. Takes {choices: {summary|chat|prompts|dictationCleanup: {kind, …}}}; an unknown kind reads as on device. Replies {languageModelSelection}.",
                kind: .mutating,
                args: [
                    .init(name: "selection", kind: .object, required: true, summary: "LanguageModelSelection JSON"),
                ],
                handler: { args, ctx in
                    guard let raw = args.rawValue("selection") else {
                        throw AutomationError.invalidArgs(field: "selection", reason: "must be a selection object")
                    }
                    guard let data = try? JSONSerialization.data(withJSONObject: raw.jsonObject),
                          let decoded = try? JSONDecoder().decode(LanguageModelSelection.self, from: data) else {
                        throw AutomationError.invalidArgs(field: "selection", reason: "could not decode the given selection")
                    }
                    ctx.model.setLanguageModelSelection(decoded)
                    return .object([
                        "languageModelSelection": ParolaAutomationServer.encode(ctx.model.languageModelSelection),
                    ])
                }
            ),

            AutomationCommand(
                name: "testAIService",
                area: .settings,
                summary: "Asks one configured service a one-line question. Replies {ok, message, ms}: message is the reply, or the error when ok is false.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Service id from getState.aiServices"),
                ],
                handler: { args, ctx in
                    let raw = try args.string("id")
                    guard let id = UUID(uuidString: raw) else {
                        throw AutomationError.invalidArgs(field: "id", reason: "must be a UUID")
                    }
                    guard let result = await ctx.model.testAIService(id: id) else {
                        throw AutomationError.notFound(kind: "aiService", id: raw)
                    }
                    return .object([
                        "ok": .bool(result.ok),
                        "message": .string(result.message),
                        "ms": .int(result.milliseconds),
                    ])
                }
            ),
        ]
    }

    /// Test mode lets a script hand over a key with the row so a cloud service can be exercised
    /// without the keychain; the key goes to the in-memory store and is never echoed back.
    private static func storeTestKeys(
        from raw: [AutomationValue],
        services: [AIServiceConfig],
        model: AppModel
    ) async throws {
        guard model.mode == .test else { return }
        var written: Set<UUID> = []
        for (value, service) in zip(raw, services) {
            guard case .object(let fields) = value,
                  case .string(let key)? = fields["apiKey"],
                  !key.isEmpty,
                  let provider = service.kind.keyProviderID
            else { continue }
            try? await model.apiKeyStore.set(key, for: provider)
            written.insert(service.id)
        }
        guard !written.isEmpty else { return }
        var updated = model.aiServices
        for index in updated.indices where written.contains(updated[index].id) {
            updated[index].hasKey = true
        }
        model.setAIServices(updated)
    }

    /// The services as the bridge reports them. The key itself never appears — only whether one is saved.
    static func aiServicesState(_ model: AppModel) -> AutomationValue {
        .array(model.aiServices.map { service in
            .object([
                "id": .string(service.id.uuidString),
                "kind": .string(service.kind.rawValue),
                "name": .string(service.name),
                "model": .string(service.model),
                "endpoint": service.endpoint.map { .string($0.absoluteString) } ?? .null,
                "hasKey": .bool(service.hasKey),
            ])
        })
    }
}
