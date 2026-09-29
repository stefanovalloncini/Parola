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

            let session = try await model.makeChatSession(transcript: try #require(model.transcript), history: [], entryID: nil)
            let reply = try await session.ask("who answers?")
            #expect(reply.text == "from openai")
        }
    }

    @Test("with nothing picked, chat answers on the on-device model through the same stand-in as every other task")
    func onDeviceChatIsMocked() async throws {
        try await withInstalledMocks {
            let model = makeModel()

            let session = try await model.makeChatSession(transcript: try #require(model.transcript), history: [], entryID: nil)
            let reply = try await session.ask("who answers?")

            #expect(reply.text == "from apple")
            #expect(await MockLanguageModelStore.shared.lastInstructions(for: .foundation)?.contains("we ship the patch on Friday") == true)
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
                    history: [],
                    entryID: nil
                )
                let reply = try await session.ask("di cosa si parla?")
                #expect(!reply.text.isEmpty)
            }
        }
    }

    @Test("a condensed chat's digest is written once, kept as the entry's summary and reused")
    func chatDigestIsKept() async throws {
        try await withInstalledMocks([.ollama: "the answer"]) {
            let model = makeModel()
            let long = Transcript(
                segments: (0..<400).map {
                    TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "parola parola parola parola parola")
                },
                language: "it",
                modelName: "stub"
            )
            let entry = try await model.library.add(transcript: long, audioSource: nil, category: .transcription)
            model.selectedEntryID = entry.id
            model.transcript = long
            pick(ollama(), for: .chat, on: model)
            let digests = DigestCounter()
            model.summariseOperation = { _, _ in
                await digests.bump()
                return Summary(text: "the digest", chapters: [Chapter(title: "Start", start: 0)])
            }

            let first = try await model.makeChatSession(transcript: long, history: [], entryID: entry.id)
            _ = try await first.ask("di cosa si parla?")

            #expect(await digests.count == 1)
            #expect(await waitUntil { model.transcript?.summary?.text == "the digest" })
            #expect(model.smartChapters.map(\.title) == ["Start"])
            let stored = try await model.library.load(entry.id).document.transcript
            #expect(stored.summary?.text == "the digest")

            let second = try await model.makeChatSession(transcript: try #require(model.transcript), history: [], entryID: entry.id)
            _ = try await second.ask("e poi?")
            #expect(await digests.count == 1)
        }
    }

    @Test("a chat's digest fills the summary but leaves the chapters the entry already had")
    func chatDigestKeepsChapters() async throws {
        try await withInstalledMocks([.ollama: "the answer"]) {
            let model = makeModel()
            var long = Transcript(
                segments: (0..<400).map {
                    TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "parola parola parola parola parola")
                },
                language: "it",
                modelName: "stub"
            )
            long.chapters = [Chapter(title: "Generated", start: 0)]
            let entry = try await model.library.add(transcript: long, audioSource: nil, category: .transcription)
            model.selectedEntryID = entry.id
            model.transcript = long
            pick(ollama(), for: .chat, on: model)
            model.summariseOperation = { _, _ in Summary(text: "the digest", chapters: [Chapter(title: "Digest start", start: 0)]) }

            let session = try await model.makeChatSession(transcript: long, history: [], entryID: entry.id)
            _ = try await session.ask("di cosa si parla?")

            #expect(await waitUntil { model.transcript?.summary?.text == "the digest" })
            #expect(model.transcript?.chapters?.map(\.title) == ["Generated"])
            let stored = try await model.library.load(entry.id).document.transcript
            #expect(stored.summary?.text == "the digest")
            #expect(stored.chapters?.map(\.title) == ["Generated"])
        }
    }

    @Test("a chat on this Mac never sends its digest to a cloud summary model")
    func chatDigestStaysWithTheChatsLocality() async throws {
        try await withInstalledMocks([.ollama: "SUMMARY:\nfrom ollama"]) {
            let model = makeModel()
            let long = Transcript(
                segments: (0..<400).map {
                    TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "parola parola parola parola parola")
                },
                language: "it",
                modelName: "stub"
            )
            let entry = try await model.library.add(transcript: long, audioSource: nil, category: .transcription)
            model.selectedEntryID = entry.id
            model.transcript = long
            pick(ollama(), for: .chat, on: model)
            pick(openAI(), for: .summary, on: model)
            #expect(model.digestTask == .chat)

            let session = try await model.makeChatSession(transcript: long, history: [], entryID: entry.id)
            _ = try await session.ask("di cosa si parla?")

            #expect(await waitUntil { model.transcript?.summary != nil })
            #expect(model.transcript?.summary?.text == "from ollama")
            #expect(model.transcript?.summary?.provider == model.languageModelLabel(for: .chat))
            #expect(await MockLanguageModelStore.shared.lastPrompt(for: .openAI) == nil)
        }
    }

    @Test("a chat digest waits on the summary already running instead of starting another")
    func chatDigestJoinsTheRunningSummary() async throws {
        let model = makeModel()
        let entry = try await model.library.add(transcript: try #require(model.transcript), audioSource: nil, category: .transcription)
        model.selectedEntryID = entry.id
        let digests = DigestCounter()
        let (release, releaser) = AsyncStream<Void>.makeStream()
        model.summariseOperation = { _, _ in
            await digests.bump()
            for await _ in release { break }
            return Summary(text: "one run")
        }

        model.summariseTranscript()
        let digest = model.chatDigest(for: entry.id, transcript: try #require(model.transcript))
        async let fromChat = digest()
        releaser.finish()

        #expect(try await fromChat.text == "one run")
        #expect(await digests.count == 1)
    }

    @Test("chapters and action items asked for on one entry land in it while another is open")
    func runsLandOnTheirEntry() async throws {
        try await withInstalledMocks {
            await MockLanguageModelStore.shared.install(
                provider: .foundation,
                response: MockLanguageModelResponse(text: "00:00 Opening", delayMs: 300)
            )
            await MockLanguageModelStore.shared.install(
                provider: .openAI,
                response: MockLanguageModelResponse(text: "- [Ada] send the deck", delayMs: 300)
            )
            let model = makeModel()
            let a = try await model.library.add(transcript: try #require(model.transcript), audioSource: nil, category: .transcription)
            let b = try await model.library.add(transcript: try #require(model.transcript), audioSource: nil, category: .transcription)
            model.selectedEntryID = a.id
            pick(openAI(), for: .prompts, on: model)

            model.extractSmartChapters()
            model.extractActionItems()
            #expect(model.isExtractingChapters && model.isExtractingActionItems)

            model.loadEntry(b.id)
            #expect(await waitUntil { model.selectedEntryID == b.id })
            #expect(!model.isExtractingChapters && !model.isExtractingActionItems)
            #expect(await waitUntil(timeoutMs: 3000) {
                !model.aiJobs.isRunning(.chapters, for: a.id) && !model.aiJobs.isRunning(.actionItems, for: a.id)
            })
            #expect(model.smartChapters.isEmpty)
            #expect(model.actionItems.isEmpty)
            let storedA = try await model.library.load(a.id).document.transcript
            #expect(storedA.chapters?.map(\.title) == ["Opening"])
            #expect(storedA.actionItems?.map(\.task) == ["send the deck"])

            model.loadEntry(a.id)
            #expect(await waitUntil { model.selectedEntryID == a.id && !model.smartChapters.isEmpty })
            #expect(model.actionItems.map(\.assignee) == ["Ada"])
        }
    }

    @Test("Clear stops an action item run and forgets the saved ones")
    func clearActionItemsCancels() async throws {
        try await withInstalledMocks {
            await MockLanguageModelStore.shared.install(
                provider: .foundation,
                response: MockLanguageModelResponse(text: "- send the deck", delayMs: 200)
            )
            let model = makeModel()
            let entry = try await model.library.add(transcript: try #require(model.transcript), audioSource: nil, category: .transcription)
            model.selectedEntryID = entry.id

            model.extractActionItems()
            #expect(model.isExtractingActionItems)
            model.clearActionItems()
            #expect(!model.isExtractingActionItems)

            try await Task.sleep(for: .milliseconds(400))
            #expect(model.actionItems.isEmpty)
            #expect(try await model.library.load(entry.id).document.transcript.actionItems == nil)
        }
    }

    @Test("a prompt's instructions travel once, as the model's own, and the turn carries only the input")
    func promptInstructionsOnce() async throws {
        try await withInstalledMocks {
            let model = makeModel()
            let prompt = try #require(Prompt.builtIns.first)

            model.runPrompt(prompt)

            #expect(await waitUntil { model.promptOutput != nil })
            #expect(await MockLanguageModelStore.shared.lastInstructions(for: .foundation) == prompt.instructions)
            #expect(await MockLanguageModelStore.shared.lastPrompt(for: .foundation) == "Input:\nwe ship the patch on Friday")
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

private actor DigestCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
