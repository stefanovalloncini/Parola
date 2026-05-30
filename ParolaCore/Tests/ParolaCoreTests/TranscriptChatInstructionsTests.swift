import Foundation
import Testing
@testable import ParolaCore

@Suite("TranscriptChat system instructions")
struct TranscriptChatInstructionsTests {
    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    @Test("opens with the answering preamble")
    func preamble() {
        let out = TranscriptChat.systemInstructions(for: transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello"),
        ]))
        #expect(out.hasPrefix("You answer questions about a transcript."))
        #expect(out.contains("Each line is prefixed with its timestamp."))
    }

    @Test("prefixes each segment with its formatted timestamp")
    func timestampedLines() {
        let out = TranscriptChat.systemInstructions(for: transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello"),
            TranscriptSegment(id: 1, start: 65, end: 70, text: "world"),
        ]))
        #expect(out.contains("\(Timecode.format(0.0))  Hello"))
        #expect(out.contains("\(Timecode.format(65.0))  world"))
    }

    @Test("trims surrounding whitespace from segment text")
    func trimsBody() {
        let out = TranscriptChat.systemInstructions(for: transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "  spaced out \n"),
        ]))
        #expect(out.contains("\(Timecode.format(0.0))  spaced out\n"))
        #expect(out.contains("spaced out \n") == false)
    }

    @Test("an empty transcript still emits the header")
    func emptyTranscript() {
        let out = TranscriptChat.systemInstructions(for: transcript([]))
        #expect(out.hasPrefix("You answer questions about a transcript."))
    }
}
