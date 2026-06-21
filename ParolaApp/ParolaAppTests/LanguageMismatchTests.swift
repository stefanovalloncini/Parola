import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Language mismatch warning")
struct LanguageMismatchTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("langmismatch"))
    }

    @Test("an English-only model with a non-English language warns and suggests a multilingual model")
    func parakeetItalianWarns() {
        let model = makeModel()
        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"
        model.selectedLanguage = "it"
        #expect(model.languageMismatchWarning != nil)
        #expect(model.languageMismatchWarning?.contains("multilingual") == true)
    }

    @Test("an English-only model with English does not warn")
    func parakeetEnglishNoWarning() {
        let model = makeModel()
        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"
        model.selectedLanguage = "en"
        #expect(model.languageMismatchWarning == nil)
    }

    @Test("an English-only model on Auto-detect does not warn")
    func parakeetAutoNoWarning() {
        let model = makeModel()
        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"
        model.selectedLanguage = nil
        #expect(model.languageMismatchWarning == nil)
    }

    @Test("a multilingual model with a non-English language does not warn")
    func whisperItalianNoWarning() {
        let model = makeModel()
        model.selectedModel = "openai_whisper-large-v3_turbo"
        model.selectedLanguage = "it"
        #expect(model.languageMismatchWarning == nil)
    }
}
