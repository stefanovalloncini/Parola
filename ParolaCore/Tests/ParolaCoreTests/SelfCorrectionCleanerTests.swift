import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Self-correction cleaner")
struct SelfCorrectionCleanerTests {
    @Test("plain text is unchanged")
    func unchanged() {
        #expect(SelfCorrectionCleaner.clean("Hello world.") == "Hello world.")
        #expect(SelfCorrectionCleaner.clean("") == "")
    }

    @Test("drops scratch-that prefix")
    func scratchThatPrefix() {
        #expect(SelfCorrectionCleaner.clean("Scratch that, hello world.") == "hello world.")
        #expect(SelfCorrectionCleaner.clean("scratch that. Hello world.") == "Hello world.")
    }

    @Test("drops scratch-that mid-paragraph")
    func scratchThatMidParagraph() {
        let input = "I think we should ship. Scratch that, hold off until Friday."
        let expected = "I think we should ship. hold off until Friday."
        #expect(SelfCorrectionCleaner.clean(input) == expected)
    }

    @Test("drops wait-no prefix")
    func waitNoPrefix() {
        #expect(SelfCorrectionCleaner.clean("Wait, no, the answer is 42.") == "the answer is 42.")
        #expect(SelfCorrectionCleaner.clean("Wait no. Forty-two.") == "Forty-two.")
    }

    @Test("collapses I-mean parenthetical")
    func iMeanParenthetical() {
        #expect(SelfCorrectionCleaner.clean("He said hi, I mean, hello.") == "He said hi, hello.")
        #expect(SelfCorrectionCleaner.clean("Three things, I mean four.") == "Three things, four.")
    }

    @Test("collapses I-meant parenthetical")
    func iMeantParenthetical() {
        #expect(SelfCorrectionCleaner.clean("Three things, I meant four.") == "Three things, four.")
    }

    @Test("does not strip scratch-that mid-sentence")
    func doesNotStripMidSentence() {
        let input = "I want to scratch that itch later."
        #expect(SelfCorrectionCleaner.clean(input) == input)
    }
}
