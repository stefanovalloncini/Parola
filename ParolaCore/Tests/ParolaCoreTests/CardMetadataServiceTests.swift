import Foundation
import Testing
@testable import ParolaCore

@Suite("Card metadata service", .serialized)
struct CardMetadataServiceTests {
    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 5, text: text)],
            language: "it", modelName: "m", sourceURL: URL(fileURLWithPath: "/tmp/a.wav")
        )
    }

    @Test("parses a two-line mock reply into title and summary")
    func parsesMock() async throws {
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(text: "\"Riunione fornitori.\"\nDistinta base e ordini al magazzino per i sensori.\n")
        )
        let meta = try await CardMetadataService.generate(
            for: transcript("Buongiorno, oggi parliamo della distinta base e degli ordini al magazzino per i sensori.")
        )
        #expect(meta == CardMetadata(title: "Riunione fornitori", summary: "Distinta base e ordini al magazzino per i sensori."))
        await MockLanguageModelStore.shared.clear()
    }

    @Test("refuses transcripts under the minimum length")
    func tooShort() async {
        await #expect(throws: CardMetadataService.Failure.tooShort) {
            _ = try await CardMetadataService.generate(for: transcript("Ciao."))
        }
    }

    @Test("refuses when the AI feature is off")
    func featureOff() async {
        let features = FeatureSet(enabled: [])
        await #expect(throws: CardMetadataService.Failure.featureDisabled) {
            _ = try await CardMetadataService.generate(for: transcript(String(repeating: "parola ", count: 20)), features: features)
        }
    }

    @Test("sanitizers strip quotes, trailing punctuation and extra lines")
    func sanitizers() {
        #expect(CardMetadata.sanitizedTitle("  \"Weekly sync.\"\nmore ") == "Weekly sync")
        #expect(CardMetadata.sanitizedSummary("First sentence here.\nSecond line") == "First sentence here.")
        #expect(CardMetadata.sanitizedSummary(String(repeating: "x", count: 200)).count == 160)
    }

    @Test("textInstructions folds in custom title and summary overrides, and falls back to the defaults when absent")
    func textInstructionsUsesOverrides() {
        let custom = CardMetadataService.textInstructions(
            CardMetadataPrompts(title: "a title mentioning the client's name", summary: "a summary noting the next steps")
        )
        #expect(custom.contains("a title mentioning the client's name"))
        #expect(custom.contains("a summary noting the next steps"))

        let defaultInstructions = CardMetadataService.textInstructions(CardMetadataPrompts())
        #expect(defaultInstructions.contains("3 to 6 words"))
        #expect(defaultInstructions.contains("140 characters"))
    }
}
