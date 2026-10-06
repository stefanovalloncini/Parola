import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

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

@Suite("Language choices")
struct LanguageChoicesTests {
    private static func name(_ code: String) -> String {
        ["en": "English", "it": "Italian", "pl": "Polish", "sv": "Swedish", "ja": "Japanese", "el": "Greek"][code] ?? code
    }

    @Test("a model lists the languages it takes: Parakeet v3 its 25, Whisper every one it was trained on")
    func listsWhatTheModelTakes() {
        let parakeet = LanguageChoices.supported(by: .only(ParakeetLanguages.v3))
        let whisper = LanguageChoices.supported(by: .all)

        #expect(parakeet == ParakeetLanguages.v3)
        #expect(whisper.isSuperset(of: ["pl", "sv", "el", "sw", "haw", "en"]))
        #expect(whisper.count >= 99)
    }

    @Test("the Mac's languages and recent ones lead, the model's own follow A–Z")
    func systemAndRecentLead() {
        let sections = LanguageChoices.sections(
            scope: .only(["en", "it", "pl", "sv"]), leading: ["it", "ja", "it"], query: "", name: Self.name
        )

        #expect(sections.top == ["it", "ja"], "Japanese leads although the model can't take it; its row says so")
        #expect(sections.rest == ["en", "pl", "sv"])
    }

    @Test("typing narrows both groups by name or code")
    func searchNarrows() {
        let sections = LanguageChoices.sections(
            scope: .only(["en", "it", "pl", "sv"]), leading: ["it"], query: "pol", name: Self.name
        )

        #expect(sections.top.isEmpty)
        #expect(sections.rest == ["pl"])
        #expect(LanguageChoices.sections(scope: .only(["en", "sv"]), leading: [], query: "SV", name: Self.name).rest == ["sv"])
    }
}

@MainActor
@Suite("Model row detail")
struct ModelRowDetailTests {
    private let turbo = ModelCatalog.variant(id: "openai_whisper-large-v3_turbo")!
    private let appleSpeech = ModelCatalog.variant(id: "apple-speech-analyzer")!

    @Test("the model popover ends on Manage models…, with no Refresh row to press")
    func noRefreshRow() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("model-popover"))
        let popover = HostedWindow(
            ModelPickerPopover(searchText: .constant(""), installedOnly: .constant(false), offersDownloads: false).environment(model),
            width: 400, height: 600
        )
        defer { popover.close() }

        let words = HostedAccessibility.words(in: popover.host)

        #expect(words.contains("Manage models…"), "\(words)")
        #expect(!words.contains("Refresh"), "\(words)")
    }

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
