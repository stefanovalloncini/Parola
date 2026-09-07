import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("English-only auto-language app notice")
struct EnglishOnlyAutoNoticeAppTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("english-only"))
    }

    @Test("an English-only model on Auto shows the notice and leaves the language untouched")
    func autoShowsNotice() {
        let model = makeModel()
        model.selectedLanguage = nil
        model.activateModel("nvidia_parakeet-tdt-0.6b-v2")

        #expect(model.selectedLanguage == nil, "activation must not silently rewrite the language")
        #expect(model.englishOnlyAutoNotice?.contains("Parakeet TDT 0.6B v2") == true)
        #expect(model.englishOnlyAutoNotice?.contains("only transcribes English") == true)
    }

    @Test("a multilingual model shows no notice")
    func multilingualShowsNoNotice() {
        let model = makeModel()
        model.activateModel("openai_whisper-large-v3_turbo")
        #expect(model.englishOnlyAutoNotice == nil)
    }

    @Test("an explicit language on an English-only model shows the mismatch warning instead of the auto notice")
    func explicitLanguageShowsMismatchNotAutoNotice() {
        let model = makeModel()
        model.selectedLanguage = "it"
        model.activateModel("nvidia_parakeet-tdt-0.6b-v2")

        #expect(model.selectedLanguage == "it", "an explicit choice must survive activation")
        #expect(model.englishOnlyAutoNotice == nil)
        #expect(model.languageMismatchWarning != nil)
    }
}
