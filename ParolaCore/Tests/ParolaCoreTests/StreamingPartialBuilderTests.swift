import Foundation
import Testing
@testable import ParolaCore

@Suite("Streaming partial builder")
struct StreamingPartialBuilderTests {
    @Test("joins segments that arrive in order")
    func inOrder() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "one")
        b.add(seek: 100, text: "two")
        b.add(seek: 200, text: "three")
        #expect(b.text == "one two three")
    }

    @Test("orders segments by seek when discovery is out of order")
    func outOfOrder() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "one")
        b.add(seek: 200, text: "three")
        b.add(seek: 100, text: "two")
        #expect(b.text == "one two three")
    }

    @Test("preserves arrival order within the same seek")
    func sameSeek() {
        var b = StreamingPartialBuilder()
        b.add(seek: 50, text: "alpha")
        b.add(seek: 50, text: "beta")
        #expect(b.text == "alpha beta")
    }

    @Test("trims whitespace and skips empty segments")
    func skipsEmpty() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "  hello  ")
        b.add(seek: 100, text: "   ")
        #expect(b.text == "hello")
    }

    @Test("empty builder has empty text")
    func emptyBuilder() {
        let b = StreamingPartialBuilder()
        #expect(b.text == "")
    }
}
