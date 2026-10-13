import Foundation
import Testing
@testable import ParolaCore

@Suite("Subtitle QC")
struct SubtitleQCTests {
    // 41 characters including spaces; tests append to hit exact rates.
    private let text41 = "abcdefghij abcdefghij abcdefghij abcdefgh"

    @Test("exactly 21 characters per second is not flagged")
    func cpsBoundaryPasses() {
        let issues = SubtitleQC.issues(text: text41 + "x", duration: 2.0, captionLength: .none)
        #expect(issues.isEmpty)
    }

    @Test("over 21 characters per second is flagged with the rounded rate")
    func cpsOverLimit() {
        let issues = SubtitleQC.issues(text: text41 + "xy", duration: 2.0, captionLength: .none)
        #expect(issues == [.tooFast(charactersPerSecond: 22)])
    }

    @Test("newlines do not count toward the reading speed")
    func cpsIgnoresNewlines() {
        // 43 raw characters wrap at .short into two lines of 42 non-newline
        // characters: exactly 21 cps over 2 s only when the newline is excluded.
        let wrappedAtShort = SubtitleQC.issues(
            text: "The quick brown fox jumps over the lazy dog",
            duration: 2.0,
            captionLength: .short
        )
        #expect(wrappedAtShort.isEmpty)
    }

    @Test("exactly 0.7 seconds is not flagged")
    func durationBoundaryPasses() {
        let issues = SubtitleQC.issues(text: "Hi there", duration: 0.7, captionLength: .none)
        #expect(issues.isEmpty)
    }

    @Test("under 0.7 seconds is flagged")
    func durationUnderMinimum() {
        let issues = SubtitleQC.issues(text: "Hi", duration: 0.69, captionLength: .none)
        #expect(issues == [.tooShort])
    }

    @Test("a word exactly at the line limit is not flagged")
    func lineBoundaryPasses() {
        let word32 = String(repeating: "a", count: 32)
        let issues = SubtitleQC.issues(text: word32, duration: 3.0, captionLength: .short)
        #expect(issues.contains(.lineTooLong(limit: 32)) == false)
    }

    @Test("an unbreakable word over the line limit is flagged")
    func lineOverLimit() {
        let word33 = String(repeating: "a", count: 33)
        let issues = SubtitleQC.issues(text: word33, duration: 3.0, captionLength: .short)
        #expect(issues.contains(.lineTooLong(limit: 32)))
    }

    @Test("wrappable text never trips the line rule")
    func wrappedTextPassesLineRule() {
        let text = "The quick brown fox jumps over the lazy dog while the cat watches the show."
        let issues = SubtitleQC.issues(text: text, duration: 6.0, captionLength: .medium)
        #expect(issues.isEmpty)
    }

    @Test("the as-is preset has no line limit")
    func nonePresetSkipsLineRule() {
        let long = String(repeating: "a", count: 200)
        let issues = SubtitleQC.issues(text: long, duration: 60.0, captionLength: .none)
        #expect(issues.isEmpty)
    }

    @Test("empty text reports no issues")
    func emptyTextPasses() {
        #expect(SubtitleQC.issues(text: "", duration: 0.1, captionLength: .short).isEmpty)
        #expect(SubtitleQC.issues(text: "  \n ", duration: 0.1, captionLength: .short).isEmpty)
    }

    @Test("zero duration skips the speed rule but still flags too short")
    func zeroDuration() {
        let issues = SubtitleQC.issues(text: "Hello", duration: 0, captionLength: .none)
        #expect(issues == [.tooShort])
    }

    @Test("a segment can trip every rule at once")
    func allRulesTogether() {
        let word40 = String(repeating: "a", count: 40)
        let neighbours = [
            TranscriptSegment(id: 0, start: 0, end: 0.5, text: word40),
            TranscriptSegment(id: 1, start: 0.5, end: 3, text: "Next."),
        ]
        let issues = SubtitleQC.issues(forSegments: neighbours, captionLength: .short)[0]
        #expect(issues == [
            .lineTooLong(limit: 32),
            .tooFast(charactersPerSecond: 80),
            .tooShort,
        ])
    }

    @Test("a lone segment is judged as the export would write it, held for the minimum cue time")
    func loneSegmentIsHeld() {
        let issues = SubtitleQC.issues(text: String(repeating: "a", count: 40), duration: 0.5, captionLength: .short)
        #expect(issues == [.lineTooLong(limit: 32), .tooFast(charactersPerSecond: 40)])
    }

    @Test("the speaker label counts toward the line the export writes")
    func labelIsJudged() {
        let word = String(repeating: "a", count: 30)
        let segment = TranscriptSegment(id: 0, start: 0, end: 10, text: word, speaker: "Ada")
        #expect(SubtitleQC.issues(forSegments: [segment], captionLength: .short).isEmpty)
        #expect(SubtitleQC.issues(forSegments: [segment], captionLength: .short, showsSpeakers: true)[0] == [.lineTooLong(limit: 32)])
        #expect(SubtitleQC.issues(for: segment, captionLength: .short, speaker: "Ada") == [.lineTooLong(limit: 32)])
    }

    @Test("a translation shown beside the text is judged too")
    func translationIsJudged() {
        let segment = TranscriptSegment(id: 0, start: 0, end: 10, text: "Good morning.")
        let wide = String(repeating: "b", count: 40)
        #expect(SubtitleQC.issues(forSegments: [segment], captionLength: .short).isEmpty)
        #expect(SubtitleQC.issues(forSegments: [segment], captionLength: .short, translations: [0: wide])[0] == [.lineTooLong(limit: 32)])
    }

    @Test("the segment convenience uses text and duration")
    func segmentConvenience() {
        let segment = TranscriptSegment(id: 3, start: 10, end: 10.5, text: "Hi")
        let issues = SubtitleQC.issues(for: segment, captionLength: .none)
        #expect(issues == [.tooShort])
    }

    private let longText = "So the thing about building a transcription app is that every part of it looks simple until you try to make it work for a two hour meeting recorded on a laptop in a noisy café, and then the captions have to fit on a phone screen held upright."

    @Test("a long segment is judged by the cues it splits into, not as one tall cue")
    func judgedPerCue() {
        let segment = TranscriptSegment(id: 0, start: 10, end: 28, text: longText)
        #expect(SubtitleQC.issues(for: segment, captionLength: .medium).isEmpty)
        #expect(SubtitleQC.issues(for: segment, captionLength: .short).isEmpty)
    }

    @Test("speech too fast for the cues is still flagged")
    func hurriedSegment() {
        let segment = TranscriptSegment(id: 0, start: 0, end: 3, text: longText)
        #expect(SubtitleQC.issues(for: segment, captionLength: .medium).contains {
            if case .tooFast = $0 { true } else { false }
        })
    }

    @Test("a word too wide for the limit is flagged even when the rest breaks fine")
    func wideWord() {
        let word = String(repeating: "a", count: 50)
        #expect(SubtitleQC.issues(text: "ok \(word)", duration: 20, captionLength: .medium) == [.lineTooLong(limit: 42)])
    }

    @Test("word timings set each cue's reading speed")
    func wordTimings() {
        let words = longText.split(separator: " ").enumerated().map { index, word in
            WordTiming(id: "w\(index)", word: String(word), start: Double(index) * 0.2, end: Double(index) * 0.2 + 0.15, probability: 1)
        }
        let fast = TranscriptSegment(id: 0, start: 0, end: 20, text: longText, words: words)
        #expect(SubtitleQC.issues(for: fast, captionLength: .medium).contains {
            if case .tooFast = $0 { true } else { false }
        })
    }
}
