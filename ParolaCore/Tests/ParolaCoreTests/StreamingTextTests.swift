import Foundation
import Testing
@testable import ParolaCore

@Suite("Streaming text split")
struct StreamingTextTests {
    @Test("the first arrival is all fresh")
    func firstArrival() {
        let parts = StreamingText.split(shown: "", latest: "Hello")
        #expect(parts.settled == "")
        #expect(parts.fresh == "Hello")
    }

    @Test("an appended update keeps the shown text settled and marks the suffix fresh")
    func appendedSuffix() {
        let parts = StreamingText.split(shown: "Hello", latest: "Hello world")
        #expect(parts.settled == "Hello")
        #expect(parts.fresh == " world")
    }

    @Test("an unchanged update has no fresh text")
    func unchanged() {
        let parts = StreamingText.split(shown: "Hello", latest: "Hello")
        #expect(parts.settled == "Hello")
        #expect(parts.fresh == "")
    }

    @Test("a rewrite that does not extend the shown text is treated as all settled")
    func rewrite() {
        let parts = StreamingText.split(shown: "Hello", latest: "Goodbye")
        #expect(parts.settled == "Goodbye")
        #expect(parts.fresh == "")
    }

    @Test("a slid tail window keeps the overlap settled and marks the appended text fresh")
    func slidTailWindow() {
        let parts = StreamingText.split(shown: "one two three", latest: "two three four")
        #expect(parts.settled == "two three")
        #expect(parts.fresh == " four")
    }

    @Test("a rewrite with only a token of overlap is still all settled")
    func rewriteWithTinyOverlap() {
        let parts = StreamingText.split(shown: "Hello", latest: "or not this time")
        #expect(parts.settled == "or not this time")
        #expect(parts.fresh == "")
    }

    @Test("the longest of several candidate overlaps wins")
    func longestOverlapWins() {
        let parts = StreamingText.split(shown: "abababab", latest: "abababXY")
        #expect(parts.settled == "ababab")
        #expect(parts.fresh == "XY")
    }

    @Test("a window that swallows the whole update leaves nothing fresh")
    func fullyConsumedUpdate() {
        let parts = StreamingText.split(shown: "the quick brown fox", latest: "brown fox")
        #expect(parts.settled == "brown fox")
        #expect(parts.fresh == "")
    }

    @Test("an engine rewrite that prepends a late piece settles the whole update")
    func prependedLatePiece() {
        let shown = String(repeating: "one two three four ", count: 40)
        let parts = StreamingText.split(shown: shown, latest: "zero " + shown)
        #expect(parts.settled == "zero " + shown)
        #expect(parts.fresh == "")
    }

    @Test("two long partials that share no border split quickly")
    func longMismatchIsQuick() {
        let base = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 1_000)
        let shown = base + "alpha"
        let latest = base + "omega"
        let clock = ContinuousClock()
        var parts: (settled: String, fresh: String) = ("", "")
        let elapsed = clock.measure { parts = StreamingText.split(shown: shown, latest: latest) }
        #expect(elapsed < .milliseconds(100))
        #expect(parts.settled == latest)
        #expect(parts.fresh == "")
    }
}
