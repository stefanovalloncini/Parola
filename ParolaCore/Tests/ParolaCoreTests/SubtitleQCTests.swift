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
        let issues = SubtitleQC.issues(text: word40, duration: 0.5, captionLength: .short)
        #expect(issues == [
            .lineTooLong(limit: 32),
            .tooFast(charactersPerSecond: 80),
            .tooShort,
        ])
    }

    @Test("the segment convenience uses text and duration")
    func segmentConvenience() {
        let segment = TranscriptSegment(id: 3, start: 10, end: 10.5, text: "Hi")
        let issues = SubtitleQC.issues(for: segment, captionLength: .none)
        #expect(issues == [.tooShort])
    }
}
