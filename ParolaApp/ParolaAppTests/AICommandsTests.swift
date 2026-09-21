import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge AI commands", .serialized)
struct AICommandsTests {

    private func makeRig(
        mode: AppBootstrap.Mode = .test,
        features: Set<ParolaFeature> = Set(ParolaFeature.allCases)
    ) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: mode,
            library: makeTempLibraryURL("aicommands"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: features,
            apiKeyStore: InMemoryAPIKeyStore()
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.aiCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func field(_ value: AutomationValue, _ key: String) throws -> AutomationValue {
        guard case .object(let fields) = value, let found = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        return found
    }

    private func run(
        _ commands: [String: AutomationCommand],
        _ name: String,
        _ args: [String: AutomationValue] = [:],
        _ context: AutomationContext
    ) async throws -> AutomationValue {
        let command = try #require(commands[name])
        return try await command.handler(try command.validate(AutomationArgs(args)), context)
    }

    private func service(id: UUID = UUID(), apiKey: String? = nil) -> AutomationValue {
        var fields: [String: AutomationValue] = [
            "id": .string(id.uuidString),
            "kind": .string("openAI"),
            "name": .string("Work OpenAI"),
            "model": .string("gpt-4o-mini"),
        ]
        if let apiKey { fields["apiKey"] = .string(apiKey) }
        return .object(fields)
    }

    @Test("setAIServices stores the row and its key, and getState never shows the key")
    func setServices() async throws {
        let (model, server, context, commands) = try makeRig()
        let id = UUID()

        let reply = try await run(commands, "setAIServices", ["services": .array([service(id: id, apiKey: "sk-secret-value")])], context)

        #expect(model.aiServices.map(\.id) == [id])
        #expect(try await model.apiKeyStore.get(for: .openAI) == "sk-secret-value")
        let rows = try field(reply, "aiServices")
        guard case .array(let list) = rows else {
            Issue.record("expected an array of services")
            return
        }
        #expect(try field(list[0], "name") == .string("Work OpenAI"))
        #expect(try field(list[0], "hasKey") == .bool(true))
        let state = ParolaAutomationServer.aiServicesState(model)
        #expect(!String(describing: state).contains("sk-secret-value"))
        withExtendedLifetime(server) {}
    }

    @Test("setLanguageModelSelection round-trips through getState")
    func setSelection() async throws {
        let (model, server, context, commands) = try makeRig()
        let id = UUID()
        _ = try await run(commands, "setAIServices", ["services": .array([service(id: id)])], context)

        let selection = AutomationValue.object([
            "choices": .object([
                "summary": .object([
                    "kind": .string("cloud"),
                    "provider": .string("openai"),
                    "model": .string("gpt-4o-mini"),
                ]),
            ]),
        ])
        let reply = try await run(commands, "setLanguageModelSelection", ["selection": selection], context)

        #expect(model.languageModelSelection[.summary] == .cloud(provider: .openAI, model: "gpt-4o-mini"))
        let stored = try field(reply, "languageModelSelection")
        let summary = try field(try field(try field(stored, "choices"), "summary"), "kind")
        #expect(summary == .string("cloud"))
        withExtendedLifetime(server) {}
    }

    /// Installs the mocks, runs the body, and clears them whether the body returns or throws.
    private func withMocks<T>(
        _ responses: [MockLanguageModelStore.Provider: String],
        _ body: () async throws -> T
    ) async throws -> T {
        await MockLanguageModelStore.shared.clear()
        for (provider, text) in responses {
            await MockLanguageModelStore.shared.install(
                provider: provider,
                response: MockLanguageModelResponse(text: text)
            )
        }
        do {
            let value = try await body()
            await MockLanguageModelStore.shared.clear()
            return value
        } catch {
            await MockLanguageModelStore.shared.clear()
            throw error
        }
    }

    @Test("testAIService reports the mocked reply and how long it took")
    func testService() async throws {
        try await withMocks([.openAI: "OK"]) {
            let (_, server, context, commands) = try makeRig()
            let id = UUID()
            _ = try await run(commands, "setAIServices", ["services": .array([service(id: id)])], context)

            let reply = try await run(commands, "testAIService", ["id": .string(id.uuidString)], context)

            #expect(try field(reply, "ok") == .bool(true))
            #expect(try field(reply, "message") == .string("OK"))
            guard case .int = try field(reply, "ms") else {
                Issue.record("expected a round-trip time")
                return
            }
            withExtendedLifetime(server) {}
        }
    }

    @Test("a key handed over outside test mode is refused, not quietly dropped")
    func apiKeyOutsideTestModeIsRefused() async throws {
        let (model, server, context, commands) = try makeRig(mode: .normal)

        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setAIServices", ["services": .array([service(apiKey: "sk-secret-value")])], context)
        }
        #expect(model.aiServices.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("a custom service with no endpoint is refused")
    func customWithoutEndpointIsRefused() async throws {
        let (model, server, context, commands) = try makeRig()
        let row = AutomationValue.object([
            "id": .string(UUID().uuidString),
            "kind": .string("custom"),
            "name": .string("My server"),
            "model": .string("m"),
        ])

        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setAIServices", ["services": .array([row])], context)
        }
        #expect(model.aiServices.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("with the AI feature off the setters fail loudly instead of doing nothing")
    func featureOffIsRefused() async throws {
        let (model, server, context, commands) = try makeRig(features: [])

        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setAIServices", ["services": .array([service()])], context)
        }
        await #expect(throws: AutomationError.self) {
            _ = try await run(
                commands,
                "setLanguageModelSelection",
                ["selection": .object(["choices": .object([:])])],
                context
            )
        }
        #expect(model.aiServices.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("remoteAIAcknowledged is settable through the bridge")
    func acknowledgementIsWritable() throws {
        #expect(ParolaAutomationServer.writableSettingKeys.contains("remoteAIAcknowledged"))
    }
}
