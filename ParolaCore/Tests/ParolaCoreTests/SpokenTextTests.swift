import Foundation
import Testing
@testable import ParolaCore

@Suite("Spoken text normalization")
struct SpokenTextTests {

    @Test("Trims surrounding whitespace and newlines")
    func trimsEdges() {
        #expect(SpokenText.normalized("  hello  ") == "hello")
        #expect(SpokenText.normalized("\n perché \n") == "perché")
    }

    @Test("Whitespace-only text becomes empty")
    func whitespaceBecomesEmpty() {
        #expect(SpokenText.normalized("   ") == "")
        #expect(SpokenText.normalized("\n\t") == "")
    }

    @Test("Punctuation-only text carries no speech and becomes empty")
    func punctuationBecomesEmpty() {
        #expect(SpokenText.normalized("...") == "")
        #expect(SpokenText.normalized("…") == "")
        #expect(SpokenText.normalized(" ... ") == "")
        #expect(SpokenText.normalized("?") == "")
        #expect(SpokenText.normalized("—") == "")
        #expect(SpokenText.normalized("♪♪♪") == "")
        #expect(SpokenText.normalized(".,!?") == "")
    }

    @Test("Text with any letter or number is kept verbatim after trimming")
    func speechIsKept() {
        #expect(SpokenText.normalized("ok.") == "ok.")
        #expect(SpokenText.normalized("3") == "3")
        #expect(SpokenText.normalized("100%") == "100%")
        #expect(SpokenText.normalized("e poi...") == "e poi...")
        #expect(SpokenText.normalized("I") == "I")
    }

    @Test("Non-Latin scripts count as speech")
    func nonLatinScriptsKept() {
        #expect(SpokenText.normalized("日本語") == "日本語")
        #expect(SpokenText.normalized("привет") == "привет")
        #expect(SpokenText.normalized("مرحبا") == "مرحبا")
    }
}
