import Foundation
import Testing
@testable import ParolaCore

@Suite("Filler word counter")
struct FillerWordCounterTests {
    @Test("counts each filler occurrence regardless of case")
    func basic() {
        let count = FillerWordCounter.count(in: "Um, hello. Uh wait, like really? You know, basically.")
        #expect(count == 6)
    }

    @Test("counts multi-word fillers as one")
    func multiWord() {
        let count = FillerWordCounter.count(in: "You know it's fine.")
        #expect(count == 1)
    }

    @Test("does not match within larger words")
    func wordBoundaries() {
        #expect(FillerWordCounter.count(in: "umbrella likewise") == 0)
    }

    @Test("empty input is zero")
    func empty() {
        #expect(FillerWordCounter.count(in: "") == 0)
        #expect(FillerWordCounter.count(in: "    ") == 0)
    }
}
