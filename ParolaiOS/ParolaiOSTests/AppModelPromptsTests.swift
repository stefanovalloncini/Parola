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
        return AppModel(libraryURL: tmp)
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
}
