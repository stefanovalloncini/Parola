import Foundation
import Testing
@testable import ParolaCore

@Suite("Prompt text")
struct TranscriptPromptTextTests {
    @Test("a diarized transcript keeps its speaker labels")
    func labelsSurvive() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Right, let's start.", speaker: "Anna"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "That's on me.", speaker: "Marco"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "I'll send the notes.", speaker: "Marco"),
            ],
            language: "en",
            modelName: "test"
        )

        #expect(transcript.promptText == """
        Anna: Right, let's start.
        Marco: That's on me.
        I'll send the notes.
        """)
    }

    @Test("a transcript without speakers reads as plain text")
    func plainWithoutSpeakers() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "one"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "two"),
            ],
            language: "en",
            modelName: "test"
        )

        #expect(transcript.promptText == "one two")
        #expect(transcript.promptText == transcript.text)
    }
}
