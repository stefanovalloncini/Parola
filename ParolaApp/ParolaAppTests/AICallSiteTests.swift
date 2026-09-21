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
    private func installMocks() async {
        await MockLanguageModelStore.shared.clear()
        await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "from apple"))
        await MockLanguageModelStore.shared.install(provider: .openAI, response: MockLanguageModelResponse(text: "from openai"))
        await MockLanguageModelStore.shared.install(provider: .ollama, response: MockLanguageModelResponse(text: "from ollama"))
        await MockLanguageModelStore.shared.install(provider: .custom, response: MockLanguageModelResponse(text: "from custom"))
    }

    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434")!

    private func openAI() -> AIServiceConfig {
        AIServiceConfig(kind: .openAI, name: "OpenAI", endpoint: nil, model: "gpt-4o-mini")
    }

    @discardableResult
    private func pick(_ service: AIServiceConfig, for task: LanguageModelTask, on model: AppModel) -> AIServiceConfig {
        model.setAIServices(model.aiServices + [service])
        model.setLanguageModel(service.choice, for: task)
        return service
    }

    private func waitUntil(timeoutMs: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    @Test("a prompt runs on the model picked for prompts")
    func promptsUseTheirChoice() async throws {
        await installMocks()
        let model = makeModel()
        pick(openAI(), for: .prompts, on: model)

        model.runPrompt(try #require(Prompt.builtIns.first))
        #expect(await waitUntil { model.promptOutput != nil })
        #expect(model.promptOutput?.text == "from openai")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("action items run on the model picked for prompts")
    func actionItemsUseThePromptChoice() async throws {
        await installMocks()
        await MockLanguageModelStore.shared.install(
            provider: .openAI,
            response: MockLanguageModelResponse(text: "- from openai")
        )
        let model = makeModel()
        pick(openAI(), for: .prompts, on: model)

        model.extractActionItems()
        #expect(await waitUntil { !model.actionItems.isEmpty })
        #expect(model.actionItems.map(\.task) == ["from openai"])

        await MockLanguageModelStore.shared.clear()
    }

    @Test("YouTube chapters run on the model picked for summaries")
    func chaptersUseTheSummaryChoice() async throws {
        await installMocks()
        let model = makeModel()
        pick(
            AIServiceConfig(kind: .ollama, name: "Ollama", endpoint: ollamaEndpoint, model: "llama3.2:3b"),
            for: .summary,
            on: model
        )

        model.generateYouTubeChapters()
        #expect(await waitUntil { model.promptOutput != nil })
        #expect(model.promptOutput?.text == "from ollama")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("a summary runs on the model picked for summaries")
    func summaryUsesItsChoice() async throws {
        await installMocks()
        await MockLanguageModelStore.shared.install(
            provider: .custom,
            response: MockLanguageModelResponse(text: "SUMMARY:\nfrom custom\n")
        )
        let model = makeModel()
        pick(
            AIServiceConfig(
                kind: .custom,
                name: "My server",
                endpoint: URL(string: "https://llm.example.com/v1")!,
                model: "m"
            ),
            for: .summary,
            on: model
        )

        model.summariseTranscript()
        #expect(await waitUntil { model.transcript?.summary != nil })
        #expect(model.transcript?.summary?.text == "from custom")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("dictation cleanup runs on the model picked for it")
    func dictationCleanupUsesItsChoice() async throws {
        await installMocks()
        let model = makeModel()
        pick(openAI(), for: .dictationCleanup, on: model)

        let processor = PromptDictationProcessor(
            defaultPrompt: try #require(Prompt.builtIns.first),
            overrides: [:],
            cleanupRunner: model.dictationCleanupRunner()
        )
        #expect(await processor.process("ciao") == "from openai")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("chat runs on the model picked for chat")
    func chatUsesItsChoice() async throws {
        await installMocks()
        let model = makeModel()
        pick(openAI(), for: .chat, on: model)

        let session = try await model.makeChatSession(transcript: try #require(model.transcript), history: [])
        #expect(try await session.ask("who answers?").text == "from openai")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("with nothing picked every task stays on the on-device model")
    func defaultsStayOnDevice() async throws {
        await installMocks()
        let model = makeModel()

        for task in LanguageModelTask.allCases {
            #expect(model.resolvedLanguageModelChoice(for: task) == .onDevice)
        }

        model.runPrompt(try #require(Prompt.builtIns.first))
        #expect(await waitUntil { model.promptOutput != nil })
        #expect(model.promptOutput?.text == "from apple")

        await MockLanguageModelStore.shared.clear()
    }

    @Test("a choice whose service is gone falls back to the on-device model")
    func staleChoiceResolvesOnDevice() async throws {
        await installMocks()
        let model = makeModel()
        let service = pick(openAI(), for: .prompts, on: model)
        #expect(model.resolvedLanguageModelChoice(for: .prompts) == service.choice)

        model.setAIServices([])
        #expect(model.resolvedLanguageModelChoice(for: .prompts) == .onDevice)

        model.runPrompt(try #require(Prompt.builtIns.first))
        #expect(await waitUntil { model.promptOutput != nil })
        #expect(model.promptOutput?.text == "from apple")

        await MockLanguageModelStore.shared.clear()
    }
}
