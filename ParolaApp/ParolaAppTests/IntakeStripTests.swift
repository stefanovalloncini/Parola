import AppKit
import Foundation
import SwiftUI
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

    @Test("under the hero Auto is spelled out; a picked language reads the same either way")
    func heroLanguageLabel() throws {
        #expect(IntakeSummary.languageLabel(selected: nil, englishOnly: false, spellsOutAuto: true) == "Auto-detect")
        #expect(IntakeSummary.languageLabel(selected: "it", englishOnly: false, spellsOutAuto: true) == SupportedLanguages.displayName(for: "it"))
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(IntakeSummary.languageLabel(selected: nil, englishOnly: false, spellsOutAuto: true, bundle: italian) == "Automatica")
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

    @Test("the options read in Italian with words of their own, not the shared Translate and Speakers")
    func italianSummary() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(
            IntakeSummary.text(model: "Whisper Turbo", language: "Auto", translates: true, identifiesSpeakers: true, bundle: italian)
                == "Whisper Turbo · Auto · Traduzione · Speaker"
        )
        #expect(String(localized: "Translate", bundle: italian) == "Traduci")
        #expect(String(localized: "Speakers", bundle: italian) == "Persone")
    }

    @Test("the speaker-count picker says what it counts, in words of its own in Italian")
    func speakerCountPicker() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("intake-speakers"))
        model.diarize = true
        let cases = [
            (locale: Locale(identifier: "en_US"), title: "Number of speakers", shared: "Speakers"),
            (locale: Locale(identifier: "it_IT"), title: "Numero di speaker", shared: "Persone"),
        ]
        for language in cases {
            let hosted = HostedWindow(
                IntakeSettingsPopover().environment(model).environment(\.locale, language.locale), width: 320, height: 420
            )
            let words = HostedAccessibility.words(in: hosted.host)
            hosted.close()
            #expect(words.contains(language.title), "\(words)")
            #expect(!words.contains(language.shared), "\(words)")
        }
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

    @Test("the popover explains an English-only model, on Auto and with a language it can't transcribe")
    func languageNotice() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("intakenotice"))
        model.selectedModel = "openai_whisper-large-v3_turbo"
        model.selectedLanguage = "it"
        #expect(IntakeSummary.languageNotice(for: model) == nil)

        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"
        model.selectedLanguage = nil
        #expect(IntakeSummary.languageNotice(for: model) != nil)
        #expect(IntakeSummary.languageNotice(for: model) == model.englishOnlyAutoNotice)

        model.selectedLanguage = "it"
        #expect(IntakeSummary.languageNotice(for: model) != nil)
        #expect(IntakeSummary.languageNotice(for: model) == model.languageMismatchWarning)
    }

    @Test("the popover shows the language notice, so it reaches more than Settings")
    func popoverShowsTheLanguageNotice() throws {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/IntakeStripTests.swift",
            with: "ParolaApp/Views/Library/IntakeStrip.swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(source.contains(
            #"if let notice = IntakeSummary.languageNotice(for: model) { Label(notice, systemImage: "exclamationmark.triangle.fill")"#
        ))
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
