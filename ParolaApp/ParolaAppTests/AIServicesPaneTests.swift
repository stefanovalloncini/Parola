import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AI services pane", .serialized)
struct AIServicesPaneTests {

    private func makeModel(
        defaults: UserDefaults,
        keyStore: any APIKeyStore = InMemoryAPIKeyStore(),
        managed: [String: Any]? = nil
    ) -> AppModel {
        if let managed {
            defaults.set(managed, forKey: "com.apple.configuration.managed")
        }
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("ai-services"),
            defaultsOverride: defaults,
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases),
            apiKeyStore: keyStore
        )
        return AppModel(bootstrap: bootstrap)
    }

    private func openAI() -> AIServiceConfig {
        AIServiceConfig(kind: .openAI, name: "Work OpenAI", endpoint: nil, model: "gpt-4o-mini")
    }

    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434")!

    @Test("services and the selection come back after a relaunch on the same defaults")
    func persistsAcrossLaunches() async throws {
        let defaults = temporaryDefaults()
        let service = openAI()
        let first = makeModel(defaults: defaults)
        first.setAIServices([service])
        first.setLanguageModel(service.choice, for: .summary)

        let second = makeModel(defaults: defaults)
        #expect(second.aiServices.map(\.id) == [service.id])
        #expect(second.aiServices.first?.model == "gpt-4o-mini")
        #expect(second.languageModelSelection[.summary] == service.choice)
        #expect(second.resolvedLanguageModelChoice(for: .summary) == service.choice)
    }

    @Test("editing a service keeps the tasks that pointed at it")
    func editingKeepsSelections() throws {
        let model = makeModel(defaults: temporaryDefaults())
        var service = openAI()
        model.setAIServices([service])
        model.setLanguageModel(service.choice, for: .prompts)

        service.model = "gpt-4.1-mini"
        model.updateAIService(service)

        #expect(model.resolvedLanguageModelChoice(for: .prompts) == service.choice)
        #expect(model.languageModelSelection[.prompts] == .cloud(provider: .openAI, model: "gpt-4.1-mini"))
    }

    @Test("a saved key lands in the key store, never in the settings")
    func keysGoToTheKeyStore() async throws {
        let defaults = temporaryDefaults()
        let keyStore = InMemoryAPIKeyStore()
        let model = makeModel(defaults: defaults, keyStore: keyStore)

        await model.saveAIService(openAI(), apiKey: "sk-secret-value")

        #expect(try await keyStore.get(for: .openAI) == "sk-secret-value")
        #expect(model.aiServices.first?.hasKey == true)
        let stored = try #require(defaults.data(forKey: "aiServices"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("sk-secret-value"))
    }

    @Test("removing the last service of a kind takes its key with it")
    func removingTheLastRowDeletesTheKey() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let model = makeModel(defaults: temporaryDefaults(), keyStore: keyStore)
        let second = AIServiceConfig(kind: .openAI, name: "Personal OpenAI", endpoint: nil, model: "gpt-4o")

        await model.saveAIService(openAI(), apiKey: "sk-secret-value")
        model.setAIServices(model.aiServices + [second])
        let first = try #require(model.aiServices.first)

        model.removeAIService(id: first.id)
        await settle()
        #expect(try await keyStore.get(for: .openAI) == "sk-secret-value")

        model.removeAIService(id: second.id)
        let openAIKeyCleared = await waitUntil { (try? await keyStore.get(for: .openAI)) == .some(nil) }
        #expect(openAIKeyCleared)
    }

    @Test("resetting the pane deletes every configured kind's key")
    func resettingThePaneDeletesTheKeys() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let model = makeModel(defaults: temporaryDefaults(), keyStore: keyStore)

        await model.saveAIService(openAI(), apiKey: "sk-secret-value")
        await model.saveAIService(
            AIServiceConfig(kind: .groq, name: "Groq", endpoint: nil, model: "llama-3.3-70b"),
            apiKey: "gsk-secret-value"
        )

        model.forgetAIServiceKeys()

        let openAIKeyCleared = await waitUntil { (try? await keyStore.get(for: .openAI)) == .some(nil) }
        #expect(openAIKeyCleared)
        let groqKeyCleared = await waitUntil { (try? await keyStore.get(for: .groq)) == .some(nil) }
        #expect(groqKeyCleared)
    }

    @Test("the one-time notice gates remote choices only, and only until it is accepted")
    func acknowledgementGate() async throws {
        let model = makeModel(defaults: temporaryDefaults())
        let cloud = openAI().choice
        let localOllama = AIServiceConfig(kind: .ollama, name: "Ollama", endpoint: ollamaEndpoint, model: "llama3.2:3b").choice
        let remoteOllama = AIServiceConfig(
            kind: .ollama,
            name: "Box",
            endpoint: URL(string: "http://ai.example.com")!,
            model: "llama3.2:3b"
        ).choice

        #expect(model.needsRemoteAIAcknowledgement(for: cloud))
        #expect(model.needsRemoteAIAcknowledgement(for: remoteOllama))
        #expect(model.needsRemoteAIAcknowledgement(for: localOllama) == false)
        #expect(model.needsRemoteAIAcknowledgement(for: .onDevice) == false)

        model.acknowledgeRemoteAI()

        #expect(model.remoteAIAcknowledged)
        #expect(model.needsRemoteAIAcknowledgement(for: cloud) == false)

        let reopened = makeModel(defaults: model.defaults)
        #expect(reopened.remoteAIAcknowledged)
    }

    /// Takes the store's lease, installs the mocks, runs the body, and clears whether the body
    /// returns or throws. The store is process-global while swift-testing runs suites in parallel,
    /// so the lease is what stops another suite from resolving these slots mid-test.
    private func withMocks<T: Sendable>(
        _ responses: [MockLanguageModelStore.Provider: String],
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        try await MockLanguageModelStore.shared.withLease {
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
    }

    @Test("Test asks the model and reports the reply")
    func testServiceReportsTheReply() async throws {
        try await withMocks([.openAI: "OK"]) {
            let model = makeModel(defaults: temporaryDefaults())
            let service = openAI()
            model.setAIServices([service])

            let result = try #require(await model.testAIService(id: service.id))
            #expect(result.ok)
            #expect(result.message == "OK")
        }
    }

    @Test("Test reports the failure instead of pretending it worked")
    func testServiceReportsFailure() async throws {
        try await withMocks([:]) {
            let model = makeModel(defaults: temporaryDefaults())
            let service = openAI()
            model.setAIServices([service])

            let result = try #require(await model.testAIService(id: service.id))
            #expect(result.ok == false)
            #expect(!result.message.isEmpty)
        }
    }

    @Test("Keep AI on this Mac keeps every service row, pausing the remote ones; the pickers offer only what may run")
    func userSwitchPausesRemoteRows() {
        let model = makeModel(defaults: temporaryDefaults())
        let cloud = openAI()
        let ollama = AIServiceConfig(kind: .ollama, name: "Ollama", endpoint: ollamaEndpoint, model: "llama3.2:3b")
        model.setAIServices([cloud, ollama])
        #expect(!model.aiServicePaused(cloud))

        model.userPrivacyMode = true
        #expect(model.listedAIServices.map(\.id) == [cloud.id, ollama.id])
        #expect(model.visibleAIServices.map(\.id) == [ollama.id])
        #expect(model.aiServicePaused(cloud))
        #expect(!model.aiServicePaused(ollama))
        #expect(model.addableAIServiceKinds == [.ollama])
    }

    @Test("managed policy hides the remote rows, tiles and picker options")
    func managedPolicyHidesRemote() throws {
        let model = makeModel(
            defaults: temporaryDefaults(),
            managed: ["disableCloudLLM": true]
        )
        let cloud = openAI()
        let ollama = AIServiceConfig(kind: .ollama, name: "Ollama", endpoint: ollamaEndpoint, model: "llama3.2:3b")
        let offBoxOllama = AIServiceConfig(
            kind: .ollama,
            name: "Box",
            endpoint: URL(string: "http://ai.example.com")!,
            model: "llama3.2:3b"
        )
        model.setAIServices([cloud, ollama, offBoxOllama])
        model.setLanguageModel(cloud.choice, for: .chat)

        #expect(model.allowsRemoteAIServices == false)
        #expect(model.listedAIServices.map(\.id) == [ollama.id])
        #expect(model.visibleAIServices.map(\.id) == [ollama.id])
        #expect(model.addableAIServiceKinds == [.ollama])
        #expect(model.resolvedLanguageModelChoice(for: .chat) == .onDevice)
    }
}
