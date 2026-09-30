import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Intake strip")
struct IntakeStripTests {
    @Test("the settings button names the model by its short name")
    func modelLabel() {
        #expect(IntakeSummary.modelLabel(id: "openai_whisper-large-v3_turbo", installedLabel: nil) == "Whisper Turbo")
        #expect(IntakeSummary.modelLabel(id: "custom-model", installedLabel: "My Custom Model") == "My Custom Model")
        #expect(IntakeSummary.modelLabel(id: "custom-model", installedLabel: nil) == "custom-model")
    }

    @Test("the language reads Auto unless one is picked or the model only knows English")
    func languageLabel() {
        #expect(IntakeSummary.languageLabel(selected: nil, englishOnly: false) == "Auto")
        #expect(IntakeSummary.languageLabel(selected: nil, englishOnly: true) == SupportedLanguages.displayName(for: "en"))
        #expect(IntakeSummary.languageLabel(selected: "it", englishOnly: false) == SupportedLanguages.displayName(for: "it"))
    }

    @Test("the button reads model · language, then each option that changes the transcript")
    func summary() {
        #expect(IntakeSummary.text(model: "Whisper Turbo", language: "Auto", translates: false, identifiesSpeakers: false)
            == "Whisper Turbo · Auto")
        #expect(IntakeSummary.text(model: "Whisper Turbo", language: "Auto", translates: true, identifiesSpeakers: false)
            == "Whisper Turbo · Auto · Translate")
        #expect(IntakeSummary.text(model: "Whisper Turbo", language: "Italian", translates: false, identifiesSpeakers: true)
            == "Whisper Turbo · Italian · Speakers")
        #expect(IntakeSummary.text(model: "Whisper Turbo", language: "Auto", translates: true, identifiesSpeakers: true)
            == "Whisper Turbo · Auto · Translate · Speakers")
    }

    @Test("the options read in Italian with the words the rest of the app uses")
    func italianSummary() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(
            IntakeSummary.text(model: "Whisper Turbo", language: "Auto", translates: true, identifiesSpeakers: true, bundle: italian)
                == "Whisper Turbo · Auto · Traduci · Persone"
        )
    }

    @Test("Translate shows only while the chosen model can translate")
    func translateFollowsTheModel() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("intakesummary"))
        model.selectedModel = "openai_whisper-large-v3_turbo"
        model.translate = true
        model.diarize = true
        #expect(IntakeSummary.text(for: model) == "Whisper Turbo · Auto · Translate · Speakers")

        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"
        #expect(!IntakeSummary.text(for: model).contains("Translate"), "Parakeet can't translate, so the run won't")
        #expect(IntakeSummary.text(for: model).hasSuffix(" · Speakers"))
    }

    @Test("the prompt offers links only when the build can fetch them")
    func prompt() {
        #expect(IntakeStrip.prompt(linksEnabled: true) == "Drop audio or video, or paste a link")
        #expect(IntakeStrip.prompt(linksEnabled: false) == "Drop audio or video")
    }

    @Test("the prompt reads in Italian")
    func italianPrompt() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(IntakeStrip.prompt(linksEnabled: true, bundle: italian) == "Trascina audio o video, oppure incolla un link")
        #expect(IntakeStrip.prompt(linksEnabled: false, bundle: italian) == "Trascina audio o video")
    }
}
