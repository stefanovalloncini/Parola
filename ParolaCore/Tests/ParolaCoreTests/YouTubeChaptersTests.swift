import Foundation
import Testing
@testable import ParolaCore

@Suite("YouTube chapters generator")
struct YouTubeChaptersTests {
    private actor MockModel: LanguageModel {
        var receivedPrompt: String = ""
        func respond(to prompt: String) async throws -> String {
            receivedPrompt = prompt
            return "00:00 Intro\n02:34 Setup\n05:12 Demo"
        }
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 60, text: "Welcome to the show."),
                TranscriptSegment(id: 1, start: 154, end: 220, text: "Now the setup."),
                TranscriptSegment(id: 2, start: 312, end: 360, text: "And a demo."),
            ],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("generator dispatches via the language model and returns its output")
    func generates() async throws {
        let model = MockModel()
        let result = try await YouTubeChapters.generate(for: makeTranscript(), model: model)
        #expect(result.contains("00:00 Intro"))
        #expect(result.contains("02:34 Setup"))
    }

    @Test("prompt embeds timestamped transcript text")
    func promptShape() async throws {
        let model = MockModel()
        _ = try await YouTubeChapters.generate(for: makeTranscript(), model: model)
        let prompt = await model.receivedPrompt
        #expect(prompt.contains("Welcome to the show."))
        #expect(prompt.contains("00:00"))
        #expect(prompt.contains("02:34"))
        #expect(prompt.contains("05:12"))
        #expect(prompt.contains("MM:SS"))
    }

    @Test("prompt uses HH:MM:SS for segments past one hour")
    func longVideoTimestamps() async throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Intro"),
                TranscriptSegment(id: 1, start: 3700, end: 3760, text: "Way later"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let model = MockModel()
        _ = try await YouTubeChapters.generate(for: transcript, model: model)
        let prompt = await model.receivedPrompt
        #expect(prompt.contains("1:01:40"))
    }
}
