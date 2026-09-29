import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("AppModel prompt guards")
@MainActor
struct AppModelPromptsTests {
    private func makeModel() throws -> AppModel {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-appmodel-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(libraryURL: tmp, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    private func transcript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
    }

    @Test("runPrompt is ignored while another prompt is running")
    func runPromptGuards() throws {
        let model = try makeModel()
        model.isRunningPrompt = true
        model.promptOutput = AppModel.PromptOutput(promptName: "Existing", text: "kept")

        model.runPrompt(Prompt.builtIns[0], on: transcript())

        #expect(model.isRunningPrompt)
        #expect(model.promptOutput?.promptName == "Existing")
        #expect(model.promptOutput?.text == "kept")
    }

    @Test("generateYouTubeChapters is ignored while another prompt is running")
    func chaptersGuards() throws {
        let model = try makeModel()
        model.isRunningPrompt = true
        model.promptOutput = AppModel.PromptOutput(promptName: "Existing", text: "kept")

        model.generateYouTubeChapters(for: transcript())

        #expect(model.isRunningPrompt)
        #expect(model.promptOutput?.promptName == "Existing")
    }

    @Test("a prompt reads the transcript with its speakers and gets its instructions once")
    func runPromptSendsPromptText() async throws {
        let model = try makeModel()
        let diarized = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi there.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello.", speaker: "Bo"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        let prompt = Prompt.builtIns[0]

        let (sent, instructions) = try await MockLanguageModelStore.shared.withLease { @MainActor in
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "cleaned"))
            model.runPrompt(prompt, on: diarized)
            let deadline = ContinuousClock.now + .seconds(5)
            while model.promptOutput == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let sent = await MockLanguageModelStore.shared.lastPrompt(for: .foundation)
            let instructions = await MockLanguageModelStore.shared.lastInstructions(for: .foundation)
            await MockLanguageModelStore.shared.clear()
            return (sent, instructions)
        }

        #expect(model.promptOutput?.text == "cleaned")
        #expect(sent == "Input:\nAda: Hi there.\nBo: Hello.")
        #expect(instructions == prompt.instructions)
    }
}
