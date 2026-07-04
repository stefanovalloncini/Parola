import Foundation
import Testing
@testable import ParolaCore

@Suite("Speech partial assembler")
struct SpeechPartialAssemblerTests {
    @Test("an empty assembler produces empty text")
    func emptyAssembler() {
        let assembler = SpeechPartialAssembler()
        #expect(assembler.text == "")
    }

    @Test("finalized segments join in arrival order")
    func finalizedInOrder() {
        var assembler = SpeechPartialAssembler()
        assembler.addFinal("Hello")
        assembler.addFinal("world")
        #expect(assembler.text == "Hello world")
    }

    @Test("empty and whitespace-only finals are skipped")
    func skipsEmptyFinals() {
        var assembler = SpeechPartialAssembler()
        assembler.addFinal("   ")
        assembler.addFinal("Hi")
        assembler.addFinal("")
        #expect(assembler.text == "Hi")
    }

    @Test("each finalized segment is trimmed of surrounding whitespace")
    func trimsWhitespace() {
        var assembler = SpeechPartialAssembler()
        assembler.addFinal("  Hi  ")
        assembler.addFinal("  there  ")
        #expect(assembler.text == "Hi there")
    }

    @Test("tail returns the whole text when under the cap")
    func tailUnderCap() {
        var assembler = SpeechPartialAssembler()
        assembler.addFinal("Hello")
        assembler.addFinal("world")
        #expect(assembler.tail() == "Hello world")
    }

    @Test("tail caps length and cuts at a word boundary")
    func tailWordBoundary() {
        var assembler = SpeechPartialAssembler()
        assembler.addFinal("alpha beta")
        assembler.addFinal("gamma delta")
        #expect(assembler.tail(maxChars: 10) == "delta")
        #expect(assembler.tail(maxChars: 11) == "gamma delta")
    }

    @Test("incremental join matches a naive re-join")
    func matchesNaiveReference() {
        var rng = SplitMix64(seed: 42)
        var assembler = SpeechPartialAssembler()
        var finals: [String] = []
        for i in 0..<60 {
            let text = i % 9 == 0 ? " " : "word\(Int.random(in: 0..<100, using: &rng))"
            assembler.addFinal(text)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { finals.append(trimmed) }
            #expect(assembler.text == finals.joined(separator: " "))
        }
        let tail = assembler.tail(maxChars: 50)
        #expect(tail.count <= 50)
        #expect(assembler.text.hasSuffix(tail))
        #expect(assembler.text.dropLast(tail.count).last == " ")
    }
}
