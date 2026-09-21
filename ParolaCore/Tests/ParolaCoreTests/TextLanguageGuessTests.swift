import Foundation
import Testing
@testable import ParolaCore

@Suite("Text language guess")
struct TextLanguageGuessTests {
    @Test("guesses Italian from an Italian paragraph")
    func italian() {
        let text = "Buongiorno a tutti, oggi parliamo della distinta base e dei componenti ordinati al magazzino."
        #expect(TextLanguageGuess.dominantLanguage(of: text) == "it")
    }

    @Test("guesses English from an English paragraph")
    func english() {
        #expect(TextLanguageGuess.dominantLanguage(of: "Ask not what your country can do for you, ask what you can do for your country.") == "en")
    }

    @Test("returns nil for empty or numeric text")
    func nothingToGuess() {
        #expect(TextLanguageGuess.dominantLanguage(of: "") == nil)
        #expect(TextLanguageGuess.dominantLanguage(of: "12 34 56") == nil)
    }
}
