import Foundation
import Testing
@testable import ParolaCore

@Suite("Sentence counter")
struct SentenceCounterTests {
    @Test("counts sentences ending in period")
    func basicCount() {
        #expect(SentenceCounter.count("One. Two. Three.") == 3)
    }

    @Test("question and exclamation marks count")
    func mixedTerminators() {
        #expect(SentenceCounter.count("Hello? Wow! Done.") == 3)
    }

    @Test("collapses repeated terminators")
    func collapsedRuns() {
        #expect(SentenceCounter.count("Done... Really??") == 2)
    }

    @Test("treats trailing text without terminator as one sentence")
    func noTrailingTerminator() {
        #expect(SentenceCounter.count("This has no period") == 1)
    }

    @Test("empty input is zero")
    func empty() {
        #expect(SentenceCounter.count("") == 0)
        #expect(SentenceCounter.count("    \n\t") == 0)
    }

    @Test("does not split on decimals or abbreviations")
    func ignoresInnerDots() {
        let text = "Pi is 3.14 and version 1.0 ships today."
        #expect(SentenceCounter.count(text) == 1)
    }

    @Test("counts a sentence that ends in a number")
    func terminatorAfterDigit() {
        #expect(SentenceCounter.count("The year was 2020. It rained.") == 2)
        #expect(SentenceCounter.count("I scored 5. You scored 3.") == 2)
    }
}
