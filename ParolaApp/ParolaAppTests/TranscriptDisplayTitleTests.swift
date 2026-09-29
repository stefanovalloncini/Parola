import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Transcript display title")
struct TranscriptDisplayTitleTests {
    private func entry(id: String, original: String, title: String? = nil, bundle: URL) -> LibraryEntry {
        LibraryEntry(
            id: id,
            bundleURL: bundle,
            manifest: ParolaDocument.Manifest(
                originalAudioName: original,
                title: title,
                modelName: "Whisper Tiny",
                language: "en",
                audioFilename: "audio.wav"
            )
        )
    }

    @Test("a reopened entry shows its title, not the bundled audio filename")
    func reopenedEntryUsesEntryTitle() {
        let bundle = URL(fileURLWithPath: "/lib/20260624-abc.parola")
        let audio = bundle.appendingPathComponent("audio.wav")
        let e = entry(id: "20260624-abc", original: "jfk.wav", bundle: bundle)
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: audio, entry: e, showsAITitle: false, fallback: "Untitled")
        #expect(title == "jfk")
    }

    @Test("a manifest title wins over the original audio name on reopen")
    func reopenedEntryUsesManifestTitle() {
        let bundle = URL(fileURLWithPath: "/lib/20260624-abc.parola")
        let audio = bundle.appendingPathComponent("audio.wav")
        let e = entry(id: "20260624-abc", original: "jfk.wav", title: "Quarterly Review", bundle: bundle)
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: audio, entry: e, showsAITitle: false, fallback: "Untitled")
        #expect(title == "Quarterly Review")
    }

    @Test("a manifest title wins over the AI title on reopen, but the AI title stands in for an untitled entry")
    func reopenedEntryPrefersManifestOverAITitle() {
        let bundle = URL(fileURLWithPath: "/lib/20260624-abc.parola")
        let audio = bundle.appendingPathComponent("audio.wav")
        var manifest = ParolaDocument.Manifest(
            originalAudioName: "jfk.wav", title: "Quarterly Review", modelName: "Whisper Tiny", language: "en",
            audioFilename: "audio.wav"
        )
        manifest.titleSource = .user
        manifest.aiTitle = "State of the union"
        let titled = LibraryEntry(id: "20260624-abc", bundleURL: bundle, manifest: manifest)
        #expect(AppModel.transcriptDisplayTitle(sourceFileURL: audio, entry: titled, showsAITitle: true, fallback: "Untitled") == "Quarterly Review")

        manifest.title = nil
        manifest.titleSource = nil
        let untitled = LibraryEntry(id: "20260624-abc", bundleURL: bundle, manifest: manifest)
        #expect(AppModel.transcriptDisplayTitle(sourceFileURL: audio, entry: untitled, showsAITitle: true, fallback: "Untitled") == "State of the union")
        #expect(AppModel.transcriptDisplayTitle(sourceFileURL: audio, entry: untitled, showsAITitle: false, fallback: "Untitled") == "jfk")
    }

    @Test("a fresh transcribe keeps the source filename even if a stale entry is still selected")
    func freshTranscribeIgnoresStaleEntry() {
        let staleBundle = URL(fileURLWithPath: "/lib/20260624-abc.parola")
        let stale = entry(id: "20260624-abc", original: "jfk.wav", bundle: staleBundle)
        let source = URL(fileURLWithPath: "/Users/me/Downloads/New Recording 133.m4a")
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: source, entry: stale, showsAITitle: false, fallback: "Untitled")
        #expect(title == "New Recording 133")
    }

    @Test("an entry with no audio falls back to its title")
    func entryWithoutAudioUsesTitle() {
        let bundle = URL(fileURLWithPath: "/lib/20260624-mtg.parola")
        let e = entry(id: "20260624-mtg", original: "", title: "Team Standup", bundle: bundle)
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: nil, entry: e, showsAITitle: false, fallback: "Untitled")
        #expect(title == "Team Standup")
    }

    @Test("a fresh transcribe with no entry uses the source filename")
    func freshTranscribeNoEntry() {
        let source = URL(fileURLWithPath: "/tmp/Interview.wav")
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: source, entry: nil, showsAITitle: false, fallback: "Untitled")
        #expect(title == "Interview")
    }

    @Test("no source and no entry uses the fallback")
    func emptyUsesFallback() {
        let title = AppModel.transcriptDisplayTitle(sourceFileURL: nil, entry: nil, showsAITitle: false, fallback: "Untitled")
        #expect(title == "Untitled")
    }
}

@MainActor
@Suite("Current transcript title")
struct CurrentTranscriptTitleTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("current-title")
        )
    }

    private func entry(id: String, original: String, title: String? = nil) -> LibraryEntry {
        LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/lib/\(id).parola"),
            manifest: ParolaDocument.Manifest(
                originalAudioName: original,
                title: title,
                modelName: "stub",
                language: "en",
                audioFilename: "audio.wav"
            )
        )
    }

    @Test("a reopened entry titles share/print with its name, not the bundled audio file")
    func reopenedEntryUsesEntryTitle() {
        let model = makeModel()
        let e = entry(id: "20260624-abc", original: "jfk.wav")
        model.libraryEntries = [e]
        model.selectedEntryID = e.id
        model.sourceFileURL = e.bundleURL.appendingPathComponent("audio.wav")
        #expect(model.currentTranscriptTitle == "jfk")
    }

    @Test("share and export naming pick up the AI title for an untitled entry, honouring the setting")
    func aiTitleFeedsShareAndExportNaming() {
        let model = makeModel()
        var manifest = ParolaDocument.Manifest(
            originalAudioName: "jfk.wav", modelName: "stub", language: "en", audioFilename: "audio.wav"
        )
        manifest.aiTitle = "Ask not"
        let e = LibraryEntry(id: "20260624-abc", bundleURL: URL(fileURLWithPath: "/lib/20260624-abc.parola"), manifest: manifest)
        model.libraryEntries = [e]
        model.selectedEntryID = e.id
        model.sourceFileURL = e.bundleURL.appendingPathComponent("audio.wav")

        #expect(model.showAITitles)
        #expect(model.currentTranscriptTitle == "Ask not")

        model.showAITitles = false
        #expect(model.currentTranscriptTitle == "jfk")
    }

    @Test("a fresh transcribe over a still-selected entry keeps the source filename")
    func freshTranscribeKeepsSourceName() {
        let model = makeModel()
        let stale = entry(id: "20260624-abc", original: "jfk.wav")
        model.libraryEntries = [stale]
        model.selectedEntryID = stale.id
        model.sourceFileURL = URL(fileURLWithPath: "/Users/me/Downloads/New Recording 133.m4a")
        #expect(model.currentTranscriptTitle == "New Recording 133")
    }
}
