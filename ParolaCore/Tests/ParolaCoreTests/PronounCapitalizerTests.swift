import Foundation
import Testing
@testable import ParolaCore

@Suite("Pronoun capitalizer")
struct PronounCapitalizerTests {
    @Test("capitalizes a lone i")
    func loneI() {
        #expect(PronounCapitalizer.applyTo("i went home") == "I went home")
        #expect(PronounCapitalizer.applyTo("then i went home") == "then I went home")
    }

    @Test("capitalizes i in contractions")
    func contractions() {
        #expect(PronounCapitalizer.applyTo("i'm fine") == "I'm fine")
        #expect(PronounCapitalizer.applyTo("i've gone") == "I've gone")
        #expect(PronounCapitalizer.applyTo("i'll see") == "I'll see")
        #expect(PronounCapitalizer.applyTo("i'd like that") == "I'd like that")
        #expect(PronounCapitalizer.applyTo("i're back") == "I're back")
    }

    @Test("leaves embedded i alone")
    func embedded() {
        #expect(PronounCapitalizer.applyTo("kim is here") == "kim is here")
        #expect(PronounCapitalizer.applyTo("icon next to it") == "icon next to it")
        #expect(PronounCapitalizer.applyTo("the ipad is mine") == "the ipad is mine")
    }

    @Test("preserves punctuation around i")
    func punctuation() {
        #expect(PronounCapitalizer.applyTo("yes, i agree.") == "yes, I agree.")
        #expect(PronounCapitalizer.applyTo("(i'm here)") == "(I'm here)")
    }

    @Test("noop on empty input")
    func empty() {
        #expect(PronounCapitalizer.applyTo("") == "")
    }
}
