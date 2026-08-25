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

@MainActor
@Suite("Assumed language notice")
struct AssumedLanguageNoticeTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("assumedlang"))
    }

    private func transcript(_ detection: LanguageDetection?) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao")],
            language: detection?.code ?? "it",
            modelName: "openai_whisper-large-v3_turbo",
            languageDetection: detection
        )
    }

    @Test("an assumed language names it and points at the toolbar")
    func assumedLanguageNotices() {
        let model = makeModel()
        model.transcript = transcript(.assumed("it"))
        let notice = model.assumedLanguageNotice
        #expect(notice != nil)
        #expect(notice?.contains("Italian") == true)
        #expect(notice?.contains("toolbar") == true)
    }

    @Test("a detected language says nothing")
    func detectedLanguageIsSilent() {
        let model = makeModel()
        model.transcript = transcript(.detected("it"))
        #expect(model.assumedLanguageNotice == nil)
    }

    @Test("a transcript saved before the detection field says nothing")
    func missingDetectionIsSilent() {
        let model = makeModel()
        model.transcript = transcript(nil)
        #expect(model.assumedLanguageNotice == nil)
    }

    @Test("no transcript, no notice")
    func emptyModelIsSilent() {
        let model = makeModel()
        #expect(model.assumedLanguageNotice == nil)
    }

    @Test("an assumed code with no readable name falls back to the code")
    func unnamedCodeFallsBackToTheCode() {
        let model = makeModel()
        model.transcript = transcript(.assumed("zz"))
        #expect(model.assumedLanguageNotice?.contains("ZZ") == true)
    }
}
