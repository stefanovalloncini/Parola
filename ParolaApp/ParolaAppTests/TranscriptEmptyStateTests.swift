import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AppModel transcript empty state")
struct TranscriptEmptyStateTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("emptystate"))
    }

    @Test("no loaded transcript is not flagged empty")
    func nilTranscriptNotEmpty() {
        #expect(makeModel().transcriptIsEmpty == false)
    }

    @Test("a transcript with zero segments is empty")
    func zeroSegmentsIsEmpty() {
        let model = makeModel()
        model.transcript = Transcript(segments: [], language: "en", modelName: "mock")
        #expect(model.transcriptIsEmpty)
    }

    @Test("a transcript whose only segment is whitespace is empty")
    func whitespaceOnlyIsEmpty() {
        let model = makeModel()
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "  \n\t ")],
            language: "en",
            modelName: "mock"
        )
        #expect(model.transcriptIsEmpty)
    }

    @Test("a transcript with any real text is not empty")
    func realTextNotEmpty() {
        let model = makeModel()
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "  "),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello.")
            ],
            language: "en",
            modelName: "mock"
        )
        #expect(model.transcriptIsEmpty == false)
    }
}
