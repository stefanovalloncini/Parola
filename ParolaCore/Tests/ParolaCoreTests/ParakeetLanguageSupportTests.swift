import Foundation
import Testing
@testable import ParolaCore

@Suite("Parakeet language support per variant")
struct ParakeetLanguageSupportTests {
    @Test("v2 accepts only English")
    func v2EnglishOnly() {
        #expect(ParakeetTranscriber.accepts(language: "en", forModel: "nvidia_parakeet-tdt-0.6b-v2"))
        #expect(!ParakeetTranscriber.accepts(language: "it", forModel: "nvidia_parakeet-tdt-0.6b-v2"))
    }

    @Test("v3 accepts its 25 languages and auto")
    func v3Multilingual() {
        #expect(ParakeetTranscriber.accepts(language: "it", forModel: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(ParakeetTranscriber.accepts(language: "IT", forModel: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(ParakeetTranscriber.accepts(language: nil, forModel: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(!ParakeetTranscriber.accepts(language: "ja", forModel: "nvidia_parakeet-tdt-0.6b-v3"))
    }

    @Test("a guessed language the variant does not speak falls back to English")
    func guessIsClampedToTheVariant() {
        let catalan = [
            TranscriptSegment(id: 0, start: 0, end: 3, text: "Bon dia a tothom, avui parlarem de la llista de materials"),
            TranscriptSegment(id: 1, start: 3, end: 6, text: "i dels components que hem demanat al magatzem."),
        ]
        #expect(TextLanguageGuess.dominantLanguage(of: catalan) == "ca", "the guess this clamp exists for")
        #expect(
            ParakeetTranscriber.resolvedLanguage(
                for: catalan, options: TranscriptionOptions(), model: "nvidia_parakeet-tdt-0.6b-v3"
            ) == ("en", .assumed("en"))
        )
    }

    @Test("a guessed language the variant speaks is kept, and a pinned one wins over the guess")
    func guessIsKeptWhenTheVariantSpeaksIt() {
        let italian = [
            TranscriptSegment(id: 0, start: 0, end: 3, text: "Buongiorno a tutti, oggi parliamo della distinta base"),
            TranscriptSegment(id: 1, start: 3, end: 6, text: "e dei componenti ordinati al magazzino."),
        ]
        var pinned = TranscriptionOptions()
        pinned.language = "DE"

        #expect(
            ParakeetTranscriber.resolvedLanguage(
                for: italian, options: TranscriptionOptions(), model: "nvidia_parakeet-tdt-0.6b-v3"
            ) == ("it", .detected("it")),
            "a guess the model can run is what the entry was detected as"
        )
        #expect(
            ParakeetTranscriber.resolvedLanguage(
                for: italian, options: TranscriptionOptions(), model: "nvidia_parakeet-tdt-0.6b-v2"
            ) == ("en", nil),
            "an English-only variant never guesses, so it has nothing to report"
        )
        #expect(
            ParakeetTranscriber.resolvedLanguage(
                for: italian, options: pinned, model: "nvidia_parakeet-tdt-0.6b-v3"
            ) == ("de", nil),
            "a language the caller named is not a detection"
        )
    }

    @Test("an unknown Parakeet id falls back to English-only")
    func unknownIdIsEnglishOnly() {
        #expect(ParakeetTranscriber.supportedLanguages(forModel: "custom/parakeet") == .only(["en"]))
    }

    @Test("static capabilities for v3 allow Italian and never translation")
    func staticCapabilities() throws {
        let caps = try #require(ModelCatalog.staticCapabilities(forID: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(caps.supportedLanguages.allows("it"))
        #expect(!caps.supportedLanguages.isEnglishOnly)
        #expect(!caps.supportsTranslate)
        let v2 = try #require(ModelCatalog.staticCapabilities(forID: "nvidia_parakeet-tdt-0.6b-v2"))
        #expect(v2.supportedLanguages.isEnglishOnly)
    }
}
