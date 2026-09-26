import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Info inspector derived stats")
struct InfoInspectorDerivedTests {
    private func segment(
        id: Int,
        start: Double,
        end: Double,
        speaker: String,
        text: String,
        probability: Double
    ) -> TranscriptSegment {
        let pieces = text.split(separator: " ")
        let step = (end - start) / Double(max(1, pieces.count))
        let words = pieces.enumerated().map { index, word in
            WordTiming(
                id: "\(id)-\(index)",
                word: String(word),
                start: start + Double(index) * step,
                end: start + Double(index + 1) * step,
                probability: probability
            )
        }
        return TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker, words: words)
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [
                segment(id: 1, start: 0, end: 20, speaker: "Speaker 1", text: "Hello there this is a test.", probability: 0.95),
                segment(id: 2, start: 20, end: 40, speaker: "Speaker 2", text: "And this part came out mumbled.", probability: 0.4),
                segment(id: 3, start: 40, end: 70, speaker: "Speaker 1", text: "Back to the first speaker again.", probability: 0.9)
            ],
            language: "en",
            modelName: "test"
        )
    }

    @Test("one pass covers speakers, confidence, speech rate and text stats")
    func derivesEverythingInOnePass() throws {
        let transcript = makeTranscript()
        let derived = try InfoInspector.derive(transcript: transcript, textVersion: 1, knownText: nil)
        #expect(derived.speakers.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(abs((derived.confidenceAverage ?? 0) - 0.75) < 0.001)
        #expect(derived.lowConfidence.map(\.id) == [2])
        #expect(derived.speechRate == SpeechRateSeries.compute(segments: transcript.segments, binSeconds: 30))
        #expect(derived.textVersion == 1)
        #expect(derived.text.charCount == transcript.text.count)
        #expect(derived.text.wordCount == 18)
        #expect(derived.text.sentenceCount == SentenceCounter.count(transcript.text))
        #expect(derived.text.fillerCount == FillerWordCounter.count(in: transcript.text))
        #expect(derived.text.topWords == WordFrequency.compute(text: transcript.text, limit: WordFrequencySection.limit))
    }

    @Test("an unchanged text reuses its counts while timing and speakers refresh")
    func reusesTheTextCounts() throws {
        let transcript = makeTranscript()
        let first = try InfoInspector.derive(transcript: transcript, textVersion: 1, knownText: nil)
        var nudged = transcript
        nudged.segments[2].start = 30
        nudged.segments[1].speaker = "Speaker 3"
        var marked = first.text
        marked.fillerCount = 99

        let second = try InfoInspector.derive(transcript: nudged, textVersion: 1, knownText: marked)

        #expect(second.text == marked)
        #expect(second.speechRate == SpeechRateSeries.compute(segments: nudged.segments, binSeconds: 30))
        #expect(second.speechRate != first.speechRate)
        #expect(second.speakers.map(\.speaker) == ["Speaker 1", "Speaker 3"])
    }

    @Test("a transcript without words or speakers derives empty sections")
    func derivesEmptySectionsWithoutWords() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 1, start: 0, end: 5, text: "Plain line.")],
            language: "en",
            modelName: "test"
        )
        let derived = try InfoInspector.derive(transcript: transcript, textVersion: 1, knownText: nil)
        #expect(derived.speakers.isEmpty)
        #expect(derived.confidenceAverage == nil)
        #expect(derived.lowConfidence.isEmpty)
        #expect(derived.speechRate.count == 1)
        #expect(derived.text.wordCount == 2)
    }
}

@MainActor
@Suite("Transcript text version")
struct TranscriptTextVersionTests {
    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("textversion"))
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello there."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Goodbye."),
            ],
            language: "en",
            modelName: "tiny"
        )
        return model
    }

    @Test("timing, speakers and chat leave the text version and the joined text alone")
    func nonTextEditsKeepTheVersion() {
        let model = makeModel()
        let text = model.transcriptText
        let version = model.transcriptTextVersion
        let fullVersion = model.transcriptVersion

        model.nudgeSegmentEnd(id: 0, frames: -3)
        model.applySegmentSpeaker("Ada", toSegmentID: 1)
        model.transcript?.chatHistory = [ChatMessage(role: .user, text: "hi")]

        #expect(model.transcript?.segments[0].end != 1)
        #expect(model.transcript?.segments[1].speaker == "Ada")
        #expect(model.transcriptVersion > fullVersion)
        #expect(model.transcriptTextVersion == version)
        #expect(model.transcriptText == text)
    }

    @Test("a text edit, a language change and a new transcript move the text version")
    func textEditsMoveTheVersion() {
        let model = makeModel()
        var version = model.transcriptTextVersion

        model.editSegment(id: 0, newText: "Hi there.")
        #expect(model.transcriptTextVersion == version + 1)
        #expect(model.transcriptText == "Hi there. Goodbye.")
        version = model.transcriptTextVersion

        model.transcript?.language = "it"
        #expect(model.transcriptTextVersion == version + 1)
        version = model.transcriptTextVersion

        model.transcript = nil
        #expect(model.transcriptTextVersion == version + 1)
        #expect(model.transcriptText == "")
    }
}
