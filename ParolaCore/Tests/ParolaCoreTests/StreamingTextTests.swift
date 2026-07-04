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
}
