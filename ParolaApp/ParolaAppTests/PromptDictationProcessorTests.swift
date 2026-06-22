import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@Suite("Prompt dictation processor")
struct PromptDictationProcessorTests {
    private func makeProcessor(language: String?) -> PromptDictationProcessor {
        PromptDictationProcessor(defaultPrompt: nil, overrides: [:], language: language)
    }

    @Test("Italian dictation keeps the lone article i lowercase")
    func italianKeepsArticleI() async {
        let out = await makeProcessor(language: "it").process("compra i libri")
        #expect(out == "Compra i libri")
    }

    @Test("English dictation capitalizes the lone pronoun i")
    func englishCapitalizesPronounI() async {
        let out = await makeProcessor(language: "en").process("compra i libri")
        #expect(out == "Compra I libri")
    }

    @Test("Unknown language defaults to English capitalization")
    func unknownLanguageDefaultsToEnglish() async {
        let out = await makeProcessor(language: nil).process("compra i libri")
        #expect(out == "Compra I libri")
    }
}
