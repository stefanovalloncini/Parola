import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Language row detail")
struct LanguageRowDetailTests {
    @Test("a language's own name is the subtitle when it differs from the localized one", arguments: [
        ("de", "Deutsch"),
        ("it", "Italiano"),
        ("ja", "日本語"),
    ])
    func endonymDiffers(code: String, expected: String) {
        #expect(SupportedLanguages.endonym(for: code) == expected)
    }

    @MainActor
    @Test("a model that takes every language gets no note")
    func openScopeHasNoNote() {
        #expect(LanguagePickerPopover.supportNote(for: "ja", scope: .all, modelName: "Whisper Turbo") == nil)
    }

    @MainActor
    @Test("a language inside the model's scope gets no note")
    func allowedLanguageHasNoNote() {
        #expect(LanguagePickerPopover.supportNote(for: "it", scope: .only(["en", "it"]), modelName: "Parakeet v3") == nil)
    }

    @MainActor
    @Test("a language outside the model's scope names the model that can't take it")
    func excludedLanguageNamesTheModel() {
        let note = LanguagePickerPopover.supportNote(for: "ja", scope: .only(["en", "it"]), modelName: "Parakeet v3")
        #expect(note == "Not supported by Parakeet v3")
    }
}

@MainActor
@Suite("Model row detail")
struct ModelRowDetailTests {
    private let turbo = ModelCatalog.variant(id: "openai_whisper-large-v3_turbo")!
    private let appleSpeech = ModelCatalog.variant(id: "apple-speech-analyzer")!

    @Test("a download in flight for this row shows its progress")
    func downloadingRowShowsProgress() {
        let phase = AppModel.Phase.downloadingModel(name: turbo.id, progress: 0.4)
        #expect(ModelPickerPopover.trailing(for: turbo, isInstalled: false, phase: phase) == .progress(0.4))
    }

    @Test("a download in flight for another row leaves this one on its install state")
    func otherDownloadLeavesTheRowAlone() {
        let phase = AppModel.Phase.downloadingModel(name: "openai_whisper-tiny", progress: 0.4)
        #expect(ModelPickerPopover.trailing(for: turbo, isInstalled: false, phase: phase) == .download(ModelPickerPopover.sizeLabel(turbo)))
    }

    @Test("an installed model shows its size plainly")
    func installedRowShowsSize() {
        #expect(ModelPickerPopover.trailing(for: turbo, isInstalled: true, phase: .idle) == .text(ModelPickerPopover.sizeLabel(turbo)))
    }

    @Test("a model still to fetch shows its size as a download")
    func uninstalledRowShowsDownload() {
        #expect(ModelPickerPopover.trailing(for: turbo, isInstalled: false, phase: .idle) == .download(ModelPickerPopover.sizeLabel(turbo)))
    }

    @Test("a built-in engine reads as built in, not as a zero-byte download")
    func builtInRowHasNoSize() {
        #expect(ModelPickerPopover.trailing(for: appleSpeech, isInstalled: true, phase: .idle) == .text("Built in"))
    }

    @Test("an English-only model says so beside its name")
    func englishOnlyBadge() {
        let variant = ModelCatalog.variant(id: "openai_whisper-tiny.en")!
        #expect(ModelPickerPopover.scopeBadge(for: variant) == "English only")
    }

    @Test("a model with a language list says how long it is")
    func restrictedScopeBadgeCountsLanguages() {
        let variant = ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v3")!
        #expect(ModelPickerPopover.scopeBadge(for: variant) == "\(ParakeetLanguages.v3.count) languages")
    }

    @Test("a model open to every language wears no badge")
    func openScopeHasNoBadge() {
        #expect(ModelPickerPopover.scopeBadge(for: turbo) == nil)
    }
}
