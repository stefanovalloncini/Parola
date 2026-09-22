import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AI call sites on the selection", .serialized)
struct AICallSiteTests {

    private func makeModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("ai-call-site"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases),
            apiKeyStore: InMemoryAPIKeyStore(keys: [.openAI: "sk-test"])
        )
        let model = AppModel(bootstrap: bootstrap)
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
        return model
    }

    /// Distinct text per provider, so a call site's answer names the model that produced it.
    private func installMocks(_ extra: [MockLanguageModelStore.Provider: String] = [:]) async {
        await MockLanguageModelStore.shared.clear()
        var responses: [MockLanguageModelStore.Provider: String] = [
            .foundation: "from apple",
            .openAI: "from openai",
            .ollama: "from ollama",
            .custom: "from custom",
        ]
        responses.merge(extra) { _, override in override }
        for (provider, text) in responses {
            await MockLanguageModelStore.shared.install(
                provider: provider,
                response: MockLanguageModelResponse(text: text)
            )
        }
    }

    /// Takes the store's lease, installs the mocks, runs the body, and clears whether the body
    /// returns or throws. The store is process-global while swift-testing runs suites in parallel,
    /// so the lease is what stops another suite from resolving these slots mid-test; a
    /// `defer { Task { … } }` would not be ordered against the next test either.
    private func withInstalledMocks<T: Sendable>(
        _ extra: [MockLanguageModelStore.Provider: String] = [:],
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        try await MockLanguageModelStore.shared.withLease {
            await installMocks(extra)
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

    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434")!

    private func openAI() -> AIServiceConfig {
        AIServiceConfig(kind: .openAI, name: "OpenAI", endpoint: nil, model: "gpt-4o-mini")
    }

    private func ollama() -> AIServiceConfig {
        AIServiceConfig(kind: .ollama, name: "Ollama", endpoint: ollamaEndpoint, model: "llama3.2:3b")
    }

    private func custom() -> AIServiceConfig {
        AIServiceConfig(
            kind: .custom,
            name: "My server",
            endpoint: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
    }

    @discardableResult
    private func pick(_ service: AIServiceConfig, for task: LanguageModelTask, on model: AppModel) -> AIServiceConfig {
        model.setAIServices(model.aiServices + [service])
        model.setLanguageModel(service.choice, for: task)
        return service
    }

    @Test("a prompt runs on the model picked for prompts")
    func promptsUseTheirChoice() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            pick(openAI(), for: .prompts, on: model)

            model.runPrompt(try #require(Prompt.builtIns.first))
            #expect(await waitUntil { model.promptOutput != nil })
            #expect(model.promptOutput?.text == "from openai")
        }
    }

    @Test("action items run on the model picked for prompts")
    func actionItemsUseThePromptChoice() async throws {
        try await withInstalledMocks([.openAI: "- from openai"]) {
            let model = makeModel()
            pick(openAI(), for: .prompts, on: model)

            model.extractActionItems()
            #expect(await waitUntil { !model.actionItems.isEmpty })
            #expect(model.actionItems.map(\.task) == ["from openai"])
        }
    }

    @Test("YouTube chapters run on the model picked for summaries")
    func chaptersUseTheSummaryChoice() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            pick(ollama(), for: .summary, on: model)

            model.generateYouTubeChapters()
            #expect(await waitUntil { model.promptOutput != nil })
            #expect(model.promptOutput?.text == "from ollama")
        }
    }

    @Test("a summary runs on the model picked for summaries and is stamped with it")
    func summaryUsesItsChoice() async throws {
        try await withInstalledMocks([.ollama: "SUMMARY:\nfrom ollama\n"]) {
            let model = makeModel()
            pick(ollama(), for: .summary, on: model)

            model.summariseTranscript()
            #expect(await waitUntil { model.transcript?.summary != nil })
            #expect(model.transcript?.summary?.text == "from ollama")
            #expect(model.transcript?.summary?.provider == "Ollama · llama3.2:3b")
        }
    }

    @Test("a summary that stays on device keeps the on-device label")
    func summaryOnDeviceKeepsItsLabel() async throws {
        try await withInstalledMocks([.foundation: "SUMMARY:\nfrom apple\n"]) {
            let model = makeModel()

            model.summariseTranscript()
            #expect(await waitUntil { model.transcript?.summary != nil })
            #expect(model.transcript?.summary?.provider == Summary.onDeviceProvider)
        }
    }

    @Test("dictation cleanup runs on the model picked for it")
    func dictationCleanupUsesItsChoice() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            pick(openAI(), for: .dictationCleanup, on: model)

            let processor = PromptDictationProcessor(
                defaultPrompt: Prompt.builtIns.first { $0.name == "Cleanup" },
                overrides: [:],
                cleanupRunner: model.dictationCleanupRunner()
            )
            let cleaned = await processor.process("ciao")
            #expect(cleaned == "from openai")
        }
    }

    @Test("chat runs on the model picked for chat")
    func chatUsesItsChoice() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            pick(openAI(), for: .chat, on: model)

            let session = try await model.makeChatSession(transcript: try #require(model.transcript), history: [])
            let reply = try await session.ask("who answers?")
            #expect(reply.text == "from openai")
        }
    }

    @Test("an over-budget transcript is condensed through the picked model, not refused")
    func chatCondensesOverBudget() async throws {
        for service in [ollama(), custom()] {
            try await withInstalledMocks([
                .ollama: "SUMMARY:\nun riassunto\n",
                .custom: "SUMMARY:\nun riassunto\n",
            ]) {
                let model = makeModel()
                model.transcript = Transcript(
                    segments: (0..<400).map {
                        TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "parola parola parola parola parola")
                    },
                    language: "it",
                    modelName: "stub"
                )
                pick(service, for: .chat, on: model)

                let session = try await model.makeChatSession(
                    transcript: try #require(model.transcript),
                    history: []
                )
                let reply = try await session.ask("di cosa si parla?")
                #expect(!reply.text.isEmpty)
            }
        }
    }

    @Test("with nothing picked every task stays on the on-device model")
    func defaultsStayOnDevice() async throws {
        try await withInstalledMocks {
            let model = makeModel()

            for task in LanguageModelTask.allCases {
                #expect(model.resolvedLanguageModelChoice(for: task) == .onDevice)
            }

            model.runPrompt(try #require(Prompt.builtIns.first))
            #expect(await waitUntil { model.promptOutput != nil })
            #expect(model.promptOutput?.text == "from apple")
        }
    }

    @Test("a choice whose service is gone falls back to the on-device model")
    func staleChoiceResolvesOnDevice() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            let service = pick(openAI(), for: .prompts, on: model)
            #expect(model.resolvedLanguageModelChoice(for: .prompts) == service.choice)

            model.setAIServices([])
            #expect(model.resolvedLanguageModelChoice(for: .prompts) == .onDevice)

            model.runPrompt(try #require(Prompt.builtIns.first))
            #expect(await waitUntil { model.promptOutput != nil })
            #expect(model.promptOutput?.text == "from apple")
        }
    }
}
