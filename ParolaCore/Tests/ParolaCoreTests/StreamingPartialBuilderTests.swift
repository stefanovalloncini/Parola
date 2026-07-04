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

    @Test("tail returns the whole text when under the cap")
    func tailUnderCap() {
        var b = StreamingPartialBuilder()
        b.add(seek: 200, text: "three")
        b.add(seek: 0, text: "one")
        b.add(seek: 100, text: "two")
        #expect(b.tail() == "one two three")
    }

    @Test("tail drops a leading half word at a mid-word cut")
    func tailMidWordCut() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "alpha beta")
        b.add(seek: 100, text: "gamma delta")
        #expect(b.text == "alpha beta gamma delta")
        #expect(b.tail(maxChars: 10) == "delta")
    }

    @Test("tail keeps a word that starts exactly at the cut")
    func tailBoundaryCut() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "alpha beta")
        b.add(seek: 100, text: "gamma delta")
        #expect(b.tail(maxChars: 11) == "gamma delta")
    }

    @Test("tail skips a cut that lands on the separator space")
    func tailSeparatorCut() {
        var b = StreamingPartialBuilder()
        b.add(seek: 0, text: "alpha beta")
        b.add(seek: 100, text: "gamma delta")
        #expect(b.tail(maxChars: 12) == "gamma delta")
    }

    @Test("tail stays ordered while out-of-order pieces stream past the cap")
    func tailSlidesOutOfOrder() {
        var b = StreamingPartialBuilder(tailBudget: 30)
        for i in stride(from: 0, to: 40, by: 2) {
            b.add(seek: (i + 1) * 100, text: "w\(i + 1)")
            b.add(seek: i * 100, text: "w\(i)")
        }
        let expected = (0..<40).map { "w\($0)" }.joined(separator: " ")
        #expect(b.text == expected)
        let tail = b.tail(maxChars: 30)
        #expect(tail.count <= 30)
        #expect(expected.hasSuffix(tail))
        #expect(String(expected.dropLast(tail.count)).hasSuffix(" "))
    }

    @Test("incremental join matches a naive re-join over random sequences")
    func matchesNaiveReference() {
        var rng = SplitMix64(seed: 0x5eed)
        for round in 0..<50 {
            var b = StreamingPartialBuilder(tailBudget: round % 2 == 0 ? 32 : 2000)
            var reference: [(seek: Int, text: String)] = []
            let pieceCount = Int.random(in: 0..<40, using: &rng)
            for i in 0..<pieceCount {
                let seek = Int.random(in: 0..<8, using: &rng) * 100
                let text = Bool.random(using: &rng) && i % 7 == 0 ? "  " : "s\(seek)n\(i)"
                b.add(seek: seek, text: text)
                reference.append((seek, text.trimmingCharacters(in: .whitespaces)))

                let naive = reference
                    .enumerated()
                    .sorted { ($0.element.seek, $0.offset) < ($1.element.seek, $1.offset) }
                    .map(\.element.text)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                #expect(b.text == naive)

                let maxChars = Int.random(in: 1...60, using: &rng)
                let tail = b.tail(maxChars: maxChars)
                #expect(tail.count <= maxChars)
                #expect(naive.hasSuffix(tail))
                if tail.count < naive.count, !tail.isEmpty {
                    let cutOnBoundary = naive.dropLast(tail.count).last == " "
                    let unbreakableWord = tail.count == maxChars && !tail.contains(" ")
                    #expect(cutOnBoundary || unbreakableWord)
                }
            }
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
