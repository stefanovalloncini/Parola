import Testing
@testable import Parola

@MainActor
@Suite("Transcribe again message")
struct RetranscribeMessageTests {
    private func ask(substitute: String? = nil) -> RetranscribeAsk {
        RetranscribeAsk(modelName: "m", language: nil, choiceLabel: "Model", substituteModelLabel: substitute)
    }

    @Test("it says the transcript is replaced and everything else is removed")
    func splitsReplacedFromRemoved() throws {
        let message = ContentSheetsModifier.retranscribeMessage(for: ask())
        let split = try #require(message.range(of: "will be removed"))
        let replaced = message[..<split.lowerBound]
        #expect(replaced.contains("transcript will be replaced"))
        for word in ["summary", "chapters", "action items", "favorites", "notes", "translation", "chat", "speaker assignments"] {
            #expect(replaced.range(of: "will be replaced").map { replaced[$0.upperBound...].contains(word) } == true, "\(word) is not in the removed list")
        }
        #expect(message.contains("a new AI title is written"))
    }

    @Test("a substitute model is named after it")
    func substituteFollows() {
        let message = ContentSheetsModifier.retranscribeMessage(for: ask(substitute: "Whisper Small"))
        #expect(message.contains("Whisper Small"))
    }
}
