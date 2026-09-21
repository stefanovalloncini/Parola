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
