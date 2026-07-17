import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Pronoun capitalizer")
struct PronounCapitalizerTests {
    @Test("capitalizes a lone i")
    func loneI() {
        #expect(PronounCapitalizer.applyTo("i went home", language: "en") == "I went home")
        #expect(PronounCapitalizer.applyTo("then i went home", language: "en") == "then I went home")
    }

    @Test("capitalizes i in contractions")
    func contractions() {
        #expect(PronounCapitalizer.applyTo("i'm fine", language: "en") == "I'm fine")
        #expect(PronounCapitalizer.applyTo("i've gone", language: "en") == "I've gone")
        #expect(PronounCapitalizer.applyTo("i'll see", language: "en") == "I'll see")
        #expect(PronounCapitalizer.applyTo("i'd like that", language: "en") == "I'd like that")
        #expect(PronounCapitalizer.applyTo("i're back", language: "en") == "I're back")
    }

    @Test("leaves embedded i alone")
    func embedded() {
        #expect(PronounCapitalizer.applyTo("kim is here", language: "en") == "kim is here")
        #expect(PronounCapitalizer.applyTo("icon next to it", language: "en") == "icon next to it")
        #expect(PronounCapitalizer.applyTo("the ipad is mine", language: "en") == "the ipad is mine")
    }

    @Test("preserves punctuation around i")
    func punctuation() {
        #expect(PronounCapitalizer.applyTo("yes, i agree.", language: "en") == "yes, I agree.")
        #expect(PronounCapitalizer.applyTo("(i'm here)", language: "en") == "(I'm here)")
    }

    @Test("noop on empty input")
    func empty() {
        #expect(PronounCapitalizer.applyTo("", language: "en") == "")
    }

    @Test("leaves a lone i alone outside explicit English")
    func nonEnglishLeavesI() {
        #expect(PronounCapitalizer.applyTo("compra i libri", language: "it") == "compra i libri")
        #expect(PronounCapitalizer.applyTo("i ragazzi sono qui", language: "it") == "i ragazzi sono qui")
        #expect(PronounCapitalizer.applyTo("i ragazzi", language: "it-IT") == "i ragazzi")
        #expect(PronounCapitalizer.applyTo("voici i amis", language: "fr") == "voici i amis")
        #expect(PronounCapitalizer.applyTo("i miei amici", language: nil) == "i miei amici")
    }

    @Test("still capitalizes i for explicit English")
    func englishStillCapitalizes() {
        #expect(PronounCapitalizer.applyTo("i think so", language: "en") == "I think so")
        #expect(PronounCapitalizer.applyTo("i think so", language: "en-US") == "I think so")
    }
}
