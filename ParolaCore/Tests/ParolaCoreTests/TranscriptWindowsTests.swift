import Foundation
import Testing
@testable import ParolaCore

@Suite("Token budget and transcript windows")
struct TranscriptWindowsTests {
    /// An hour of speech: 120 segments, 30 s apart, about 200 bytes each.
    private func hourLong() -> Transcript {
        Transcript(
            segments: (0..<120).map { i in
                TranscriptSegment(
                    id: i,
                    start: Double(i) * 30,
                    end: Double(i) * 30 + 28,
                    text: "part\(i) " + String(repeating: "we talked about the plan for the launch ", count: 5)
                )
            },
            language: "en",
            modelName: "tiny"
        )
    }

    /// Apple's 4,096-token window with the fallback count, so no test depends on this Mac's model.
    private let smallOnDevice = TokenBudget(contextTokens: 4096, answerTokens: 1024, counting: .bytes(perToken: 3))

    @Test("each provider's budget comes from its own window")
    func budgetPerChoice() {
        #expect(TokenBudget.tokens(for: .cloud(provider: .openAI, model: "gpt-4o-mini")) == 128_000 - 4096)
        #expect(TokenBudget.tokens(for: .cloud(provider: .anthropic, model: "claude-haiku-4-5")) == 200_000 - 4096)
        #expect(TokenBudget.tokens(for: .ollama(endpoint: URL(string: "http://127.0.0.1:11434")!, model: "llama3.2:3b")) == 8192 - 4096)
        #expect(TokenBudget.tokens(for: .custom(baseURL: URL(string: "http://10.0.0.2:8080/v1")!, model: "m")) == 4096)
        let onDevice = TokenBudget(for: .onDevice)
        #expect(onDevice.contextTokens >= 4096)
        #expect(onDevice.tokens == onDevice.contextTokens - onDevice.contextTokens / 4)
    }

    @Test("windows cover every segment in order and each fits the budget")
    func windowsCoverAndFit() async {
        let transcript = hourLong()
        let windows = await TranscriptWindows.split(
            transcript,
            budget: smallOnDevice,
            instructions: "Summarise.",
            line: TranscriptPromptContext.timestampedLine(for:),
            render: TranscriptPromptContext.timestampedLines(for:)
        )
        #expect(windows.count > 1)
        #expect(windows.flatMap(\.transcript.segments) == transcript.segments)
        for window in windows {
            #expect(smallOnDevice.estimate("Summarise.") + smallOnDevice.estimate(window.text) <= smallOnDevice.tokens)
        }
    }

    @Test("a window the line costs underrate is halved until it fits")
    func verificationHalvesAWindow() async {
        let transcript = hourLong()
        let windows = await TranscriptWindows.split(
            transcript,
            budget: smallOnDevice,
            instructions: "",
            line: { _ in nil },
            render: TranscriptPromptContext.timestampedLines(for:)
        )
        #expect(windows.count > 1)
        #expect(windows.flatMap(\.transcript.segments) == transcript.segments)
        for window in windows {
            #expect(smallOnDevice.estimate(window.text) <= smallOnDevice.tokens)
        }
    }

    @Test("a long summary never sends a call over the budget")
    func summaryCallsFit() async throws {
        let model = MockLanguageModel()
        _ = try await SummaryService(budget: smallOnDevice, features: .all).summarise(hourLong(), model: model)
        let prompts = await model.receivedPrompts
        #expect(prompts.count > 2)
        let instructions = SummaryService.textInstructions(for: .default)
        for prompt in prompts {
            #expect(smallOnDevice.estimate(instructions) + smallOnDevice.estimate(prompt) <= smallOnDevice.tokens)
        }
    }

    @Test("a cloud model takes the same summary in one call")
    func cloudWindowsAreLarger() async throws {
        let onDevice = MockLanguageModel()
        _ = try await SummaryService(budget: smallOnDevice, features: .all).summarise(hourLong(), model: onDevice)
        let cloud = MockLanguageModel()
        let cloudBudget = TokenBudget(for: .cloud(provider: .openAI, model: "gpt-4o-mini"))
        _ = try await SummaryService(budget: cloudBudget, features: .all).summarise(hourLong(), model: cloud)
        #expect(await cloud.receivedPrompts.count == 1)
        #expect(await onDevice.receivedPrompts.count > 2)
    }

    @Test("a long prompt run sends windows small enough for an answer as long as each, and joins the answers in order")
    func promptWindowsFit() async throws {
        let prompt = Prompt(name: "Cleanup", instructions: "Clean up the transcript below.")
        let transcript = hourLong()
        let windowCount = await TranscriptWindows.split(
            transcript,
            budget: smallOnDevice,
            instructions: prompt.instructions,
            answer: .asLongAsInput,
            line: { $0.text + "\n" },
            render: { PromptRunner.buildUserMessage(for: prompt, text: $0.promptText) }
        ).count
        let model = MockLanguageModel(scriptedResponses: (0..<windowCount).map { "answer \($0)" })

        let result = try await PromptRunner.run(prompt, on: transcript, model: model, budget: smallOnDevice, features: .all)

        let prompts = await model.receivedPrompts
        #expect(prompts.count == windowCount)
        #expect(prompts.count > 1)
        let fixed = smallOnDevice.estimate(prompt.instructions)
        for sent in prompts {
            #expect(smallOnDevice.estimate(sent) <= (smallOnDevice.contextTokens - fixed) / 2)
        }
        #expect(result == (0..<windowCount).map { "answer \($0)" }.joined(separator: "\n\n"))
        #expect(prompts.first?.contains("part0 ") == true)
        #expect(prompts.last?.contains("part119 ") == true)
    }

    @Test("a rewrite on a cloud model is cut to what one answer can hold; a list is not")
    func cloudRewriteWindowsFollowTheAnswerCap() async throws {
        let cloud = TokenBudget(for: .cloud(provider: .anthropic, model: "claude-haiku-4-5"))
        #expect(cloud.maxAnswerTokens == 4096)
        let rewrite = MockLanguageModel()
        _ = try await PromptRunner.run(
            Prompt(name: "Cleanup", instructions: "Clean up the transcript below."),
            on: hourLong(), model: rewrite, budget: cloud, features: .all
        )
        let rewritePrompts = await rewrite.receivedPrompts
        #expect(rewritePrompts.count > 1)
        for sent in rewritePrompts {
            #expect(cloud.estimate(sent) <= 4096)
        }

        let list = MockLanguageModel()
        let actionItems = try #require(Prompt.builtIns.first { $0.name == "Action items" })
        #expect(actionItems.answerLength == .brief)
        _ = try await PromptRunner.run(actionItems, on: hourLong(), model: list, budget: cloud, features: .all)
        #expect(await list.receivedPrompts.count == 1)
    }

    @Test("a brief answer lets each on-device window carry more of the transcript")
    func briefAnswersTakeLargerWindows() async throws {
        let prompt = Prompt(name: "Questions", instructions: "List every question asked in the text below.")
        let asLong = MockLanguageModel()
        _ = try await PromptRunner.run(prompt, on: hourLong(), model: asLong, budget: smallOnDevice, features: .all)
        let brief = MockLanguageModel()
        _ = try await PromptRunner.run(prompt, on: hourLong(), model: brief, budget: smallOnDevice, answer: .brief, features: .all)
        #expect(await brief.receivedPrompts.count < asLong.receivedPrompts.count)
        #expect(Prompt.builtIns.first { $0.name == "Cleanup" }?.answerLength == .asLongAsInput)
        #expect(Prompt.builtIns.first { $0.name == "Extract questions" }?.answerLength == .brief)
    }

    @Test("a short prompt run is one call with the transcript's prompt text")
    func shortPromptIsOneCall() async throws {
        let prompt = Prompt(name: "Cleanup", instructions: "Clean up the transcript below.")
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi there.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello.", speaker: "Bo"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let model = MockLanguageModel(scriptedResponses: ["done"])
        let result = try await PromptRunner.run(prompt, on: transcript, model: model, budget: smallOnDevice, features: .all)
        #expect(result == "done")
        #expect(await model.receivedPrompts == [PromptRunner.buildUserMessage(for: prompt, text: transcript.promptText)])
    }

    @Test("long chapters are asked window by window, each kept to its own span")
    func chaptersPerWindow() async throws {
        let transcript = hourLong()
        let model = MockLanguageModel(scriptedResponses: (0..<40).map { _ in "00:00 Opening\n20:00 Middle\n59:00 Closing" })
        let chapters = try await SmartChapters.generate(for: transcript, model: model, budget: smallOnDevice)
        let prompts = await model.receivedPrompts
        #expect(prompts.count > 1)
        #expect(prompts[0].contains("MUST start at 00:00"))
        #expect(!prompts[1].contains("MUST start at 00:00"))
        for prompt in prompts {
            #expect(smallOnDevice.estimate(LanguageModelFactory.defaultInstructions) + smallOnDevice.estimate(prompt) <= smallOnDevice.tokens)
        }
        #expect(chapters.first?.start == 0)
        #expect(chapters.map(\.start) == chapters.map(\.start).sorted())
        #expect(Set(chapters.map(\.start)).count == chapters.count)
    }

    @Test("long YouTube chapters come back as one merged list")
    func youTubeChaptersPerWindow() async throws {
        let model = MockLanguageModel(scriptedResponses: (0..<40).map { _ in "00:00 Opening\n59:00 Closing" })
        let result = try await YouTubeChapters.generate(for: hourLong(), model: model, budget: smallOnDevice)
        #expect(await model.receivedPrompts.count > 1)
        let lines = result.split(separator: "\n")
        #expect(lines.first == "00:00 Opening")
        #expect(lines.last == "59:00 Closing")
        #expect(lines.count == 2)
    }
}
