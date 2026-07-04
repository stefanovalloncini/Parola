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
}
