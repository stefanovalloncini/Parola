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

    @Test("a run of segments is guessed from a prefix, not the whole transcript")
    func segmentsPrefix() {
        let opening = TranscriptSegment(id: 0, start: 0, end: 1, text: String(repeating: "Buongiorno a tutti, parliamo della distinta base. ", count: 100))
        let later = TranscriptSegment(id: 1, start: 1, end: 2, text: String(repeating: "Ask not what your country can do for you. ", count: 100))
        #expect(TextLanguageGuess.dominantLanguage(of: [opening, later]) == "it")
        #expect(TextLanguageGuess.dominantLanguage(of: [TranscriptSegment]()) == nil)
    }
}
