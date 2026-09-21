import Foundation
import Testing
import Translation
@testable import Parola
import ParolaCore

@Suite("Translation batcher")
struct TranslationBatcherTests {

    private func units(_ count: Int) -> [TranslationBatcher.Unit] {
        (0..<count).map { (id: $0 * 2, text: "segment \($0)") }
    }

    @Test("a batch never holds more than sixty segments", arguments: [59, 60, 61, 121])
    func batchSizes(_ count: Int) {
        let batches = TranslationBatcher.batches(units(count))
        let expectedCount = (count + 59) / 60

        #expect(batches.count == expectedCount)
        #expect(batches.allSatisfy { $0.count <= 60 })
        #expect(batches.reduce(0) { $0 + $1.count } == count)
        #expect(batches.dropLast().allSatisfy { $0.count == 60 })
    }

    @Test("batching keeps every segment once, in order")
    func batchesPreserveOrder() {
        let ids = TranslationBatcher.batches(units(121)).flatMap { $0.map(\.id) }

        #expect(ids == units(121).map(\.id))
    }

    @Test("nothing to translate makes no batch")
    func emptyMakesNoBatch() {
        #expect(TranslationBatcher.batches([]).isEmpty)
    }

    @Test("blank segments never reach a request")
    func unitsSkipBlankSegments() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "  Ciao  "),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "   "),
            TranscriptSegment(id: 2, start: 2, end: 3, text: "Mondo"),
        ]
        let units = TranslationBatcher.units(from: segments)

        #expect(units.map(\.id) == [0, 2])
        #expect(units.map(\.text) == ["Ciao", "Mondo"])
    }

    @Test("a request carries its segment id")
    func requestsCarrySegmentIDs() {
        let requests = TranslationBatcher.requests(for: [(id: 7, text: "Ciao"), (id: 9, text: "Mondo")])

        #expect(requests.map(\.sourceText) == ["Ciao", "Mondo"])
        #expect(requests.map(\.clientIdentifier) == ["7", "9"])
    }

    @Test("responses land back on the segments that asked")
    func responsesMapBackToSegments() {
        let responses = [
            response(targetText: "Hello", clientIdentifier: "7"),
            response(targetText: "World", clientIdentifier: "9"),
        ]

        #expect(TranslationBatcher.reassemble(responses) == [7: "Hello", 9: "World"])
    }

    @Test("a response without a usable id is dropped rather than misfiled")
    func responsesWithoutIDsAreDropped() {
        let responses = [
            response(targetText: "Hello", clientIdentifier: "7"),
            response(targetText: "Orphan", clientIdentifier: nil),
            response(targetText: "Nonsense", clientIdentifier: "not-a-number"),
        ]

        #expect(TranslationBatcher.reassemble(responses) == [7: "Hello"])
    }

    private func response(targetText: String, clientIdentifier: String?) -> TranslationSession.Response {
        TranslationSession.Response(
            sourceLanguage: Locale.Language(identifier: "it"),
            targetLanguage: Locale.Language(identifier: "en"),
            sourceText: "source",
            targetText: targetText,
            clientIdentifier: clientIdentifier
        )
    }
}
