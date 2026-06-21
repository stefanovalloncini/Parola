import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Sentence capitalizer")
struct SentenceCapitalizerTests {
    @Test("uppercases the first letter of the input")
    func firstLetter() {
        #expect(SentenceCapitalizer.applyTo("hello world.") == "Hello world.")
    }

    @Test("uppercases after a period and a space")
    func afterPeriod() {
        #expect(SentenceCapitalizer.applyTo("Hello. world.") == "Hello. World.")
    }

    @Test("uppercases after question marks and exclamation marks")
    func afterQuestionAndBang() {
        #expect(SentenceCapitalizer.applyTo("hi? you. hey! ok.") == "Hi? You. Hey! Ok.")
    }

    @Test("uppercases after a newline")
    func afterNewline() {
        #expect(SentenceCapitalizer.applyTo("first.\nsecond line") == "First.\nSecond line")
    }

    @Test("does not touch letters that are already uppercase")
    func keepsExisting() {
        #expect(SentenceCapitalizer.applyTo("Already Capital. Yes.") == "Already Capital. Yes.")
    }

    @Test("ignores non-letter starts gracefully")
    func leadingWhitespace() {
        #expect(SentenceCapitalizer.applyTo("   hello.") == "   Hello.")
    }

    @Test("empty input returns empty")
    func empty() {
        #expect(SentenceCapitalizer.applyTo("") == "")
    }

    @Test("uppercases a sentence-initial sharp s without trapping")
    func sharpSStart() {
        #expect(SentenceCapitalizer.applyTo("ßlah. ok.") == "SSlah. Ok.")
    }

    @Test("uppercases a sentence-initial ligature without trapping")
    func ligatureStart() {
        #expect(SentenceCapitalizer.applyTo("ﬁle. done.") == "FIle. Done.")
    }
}
