import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AppModel cached transcript text")
struct TranscriptTextCacheTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("transcripttext")
        )
    }

    private func transcript(_ texts: [String]) -> Transcript {
        let segments = texts.enumerated().map { idx, text in
            TranscriptSegment(id: idx, start: Double(idx), end: Double(idx) + 1, text: text)
        }
        return Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    @Test("matches the canonical join")
    func matchesCanonicalJoin() throws {
        let model = makeModel()
        model.transcript = transcript(["Hello world.", "  ", " Second one. "])

        let expected = try #require(model.transcript?.text)
        #expect(model.transcriptText == expected)
    }

    @Test("repeated reads return the same text")
    func repeatedReadsAreStable() {
        let model = makeModel()
        model.transcript = transcript(["Hello world.", "Second one."])

        #expect(model.transcriptText == model.transcriptText)
        #expect(model.transcriptText == "Hello world. Second one.")
    }

    @Test("an edit invalidates the cached text")
    func editInvalidatesCache() {
        let model = makeModel()
        model.transcript = transcript(["Hello world.", "Second one."])
        #expect(model.transcriptText == "Hello world. Second one.")

        model.editSegment(id: 0, newText: "Howdy world.")

        #expect(model.transcriptText == "Howdy world. Second one.")
    }

    @Test("clearing the transcript empties the text")
    func clearingEmptiesText() {
        let model = makeModel()
        model.transcript = transcript(["Hello world."])
        #expect(model.transcriptText == "Hello world.")

        model.transcript = nil

        #expect(model.transcriptText.isEmpty)
    }

    @Test("the cached text tracks a whole-transcript replacement")
    func replacementInvalidatesCache() {
        let model = makeModel()
        model.transcript = transcript(["First."])
        #expect(model.transcriptText == "First.")

        model.transcript = transcript(["Second.", "Third."])

        #expect(model.transcriptText == "Second. Third.")
    }
}
