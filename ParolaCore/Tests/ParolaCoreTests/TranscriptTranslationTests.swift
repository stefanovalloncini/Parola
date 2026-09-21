import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript translation")
struct TranscriptTranslationTests {

    private func translation(_ segments: [Int: String]) -> TranscriptTranslation {
        TranscriptTranslation(
            targetLanguage: "en",
            segments: segments,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "mock"
        )
    }

    @Test("a translated transcript round-trips through JSON")
    func roundTrip() throws {
        var transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Ciao mondo"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Come stai?"),
            ],
            language: "it",
            modelName: "tiny"
        )
        transcript.translation = translation([0: "Hello world", 1: "How are you?"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Transcript.self, from: encoder.encode(transcript))

        #expect(decoded == transcript)
        #expect(decoded.translation?.targetLanguage == "en")
        #expect(decoded.translation?.segments[1] == "How are you?")
        #expect(decoded.translation?.provider == "mock")
    }

    @Test("a transcript written before translations still decodes")
    func legacyDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "transcript-legacy", withExtension: "json"))
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))

        #expect(decoded.translation == nil)
        #expect(decoded.segments.count == 1)
    }

    @Test("an untranslated transcript writes no translation key")
    func noKeyWhenAbsent() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "tiny"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(transcript), encoding: .utf8))

        #expect(!json.contains("translation"))
    }

    @Test("split moves the text to the first half and leaves the second empty")
    func afterSplit() {
        let remapped = translation([4: "four", 9: "nine"]).afterSplit(of: 4, into: 20)

        #expect(remapped.segments == [20: "four", 9: "nine"])
        #expect(remapped.targetLanguage == "en")
    }

    @Test("split of an untranslated segment changes nothing")
    func afterSplitUntranslated() {
        let remapped = translation([9: "nine"]).afterSplit(of: 4, into: 20)

        #expect(remapped.segments == [9: "nine"])
    }

    @Test("merge joins both texts with a single space")
    func afterMerge() {
        #expect(translation([4: "four", 5: "five"]).afterMerge(of: 4, with: 5).segments == [4: "four five"])
        #expect(translation([4: "four"]).afterMerge(of: 4, with: 5).segments == [4: "four"])
        #expect(translation([5: "five"]).afterMerge(of: 4, with: 5).segments == [4: "five"])
        #expect(translation([8: "eight"]).afterMerge(of: 4, with: 5).segments == [8: "eight"])
    }

    @Test("delete drops the segment's text")
    func afterDelete() {
        #expect(translation([4: "four", 8: "eight"]).afterDelete(of: 4).segments == [8: "eight"])
    }
}
