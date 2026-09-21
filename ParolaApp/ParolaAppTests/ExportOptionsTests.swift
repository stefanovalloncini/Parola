import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export options sheet routing")
struct ExportOptionsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: defaults ?? makeIsolatedDefaults(),
            libraryURL: makeTempLibraryURL("exportoptions")
        )
    }

    private static func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("the Export sheet opens on the first preset and queues its spec")
    func sheetOpensOnTheFirstPreset() {
        let model = makeModel()
        model.transcript = Self.makeTranscript()

        model.openExportSheet()

        #expect(model.exportSheetOpen)
        #expect(model.exportSheetSpec == model.exportPresets.first?.spec)
        #expect(model.pendingExport == nil)
    }

    @Test("Export As queues a preset without opening the sheet")
    func exportAsSkipsTheSheet() {
        let model = makeModel()
        model.transcript = Self.makeTranscript()
        let pdf = ExportPreset.builtIn(for: .pdf)!

        model.exportWithPreset(pdf.id)

        #expect(model.pendingExport == pdf.spec)
        #expect(model.exportSheetOpen == false)
    }

    @Test("neither route does anything without a transcript")
    func exportNeedsTranscript() {
        let model = makeModel()

        model.openExportSheet()
        model.exportWithPreset(ExportPreset.builtIn(for: .pdf)!.id)

        #expect(model.exportSheetOpen == false)
        #expect(model.pendingExport == nil)
    }

    @Test("the export spec threads the txt timestamps choice into the exporter")
    func exportSpecHonorsTxtTimestamps() {
        let model = makeModel()

        model.txtExportTimestamps = true
        #expect(model.exportSpec(for: .txt).options.timestamps)
        #expect(model.makeExporter(for: .txt).spec.options.timestamps)

        model.txtExportTimestamps = false
        #expect(model.exportSpec(for: .txt).options.timestamps == false)
    }

    @Test("an explicit includeTimestamps overrides the saved preference in both directions")
    func exportSpecHonorsTimestampOverride() {
        let model = makeModel()

        model.txtExportTimestamps = false
        model.markdownTimestamps = false
        #expect(model.exportSpec(for: .txt, includeTimestamps: true).options.timestamps)
        #expect(model.exportSpec(for: .md, includeTimestamps: true).options.timestamps)
        #expect(model.exportSpec(for: .html, includeTimestamps: false).options.timestamps == false)

        model.txtExportTimestamps = true
        model.markdownTimestamps = true
        #expect(model.exportSpec(for: .txt, includeTimestamps: false).options.timestamps == false)
        #expect(model.exportSpec(for: .md, includeTimestamps: false).options.timestamps == false)
        #expect(model.exportSpec(for: .txt).options.timestamps)
    }

    @Test("the export spec carries the saved caption length and HTML theme")
    func exportSpecCarriesSharedOptions() {
        let model = makeModel()
        model.subtitleCaptionLengthRaw = CaptionLength.short.rawValue
        model.htmlExportThemeRaw = HtmlExportTheme.sepia.rawValue

        #expect(model.exportSpec(for: .srt).options.captionLength == .short)
        #expect(model.exportSpec(for: .vtt).options.captionLength == .short)
        #expect(model.exportSpec(for: .html).options.htmlTheme == .sepia)
    }

    @Test("txt timestamps persist to defaults and survive reloadSettings")
    func txtTimestampsRoundTrip() {
        let defaults = makeIsolatedDefaults()
        let model = makeModel(defaults: defaults)

        model.txtExportTimestamps = true
        #expect(defaults.bool(forKey: "txtExportTimestamps"))

        model.txtExportTimestamps = false
        model.reloadSettings()
        #expect(model.txtExportTimestamps == false)

        defaults.set(true, forKey: "txtExportTimestamps")
        model.reloadSettings()
        #expect(model.txtExportTimestamps)
    }

    @Test("a fresh model reads the persisted txt timestamps choice")
    func txtTimestampsReadAtInit() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "txtExportTimestamps")

        let model = makeModel(defaults: defaults)

        #expect(model.txtExportTimestamps)
    }
}

@MainActor
@Suite("Saved document provenance")
struct SavedDocumentSourceTests {
    private func makeModel(picker: TestFilePicker) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            filePicker: picker,
            libraryURL: makeTempLibraryURL("saved-document")
        )
    }

    private func temporaryAudio(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-saved-document-\(label)-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func entry(id: String, source: EntrySource) -> LibraryEntry {
        LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/SavedDocumentSourceTests/\(id).parola"),
            manifest: ParolaDocument.Manifest(
                originalAudioName: "audio.m4a", modelName: "stub", language: "en", source: source
            )
        )
    }

    private func waitForBundle(at url: URL, timeoutMs: Int = 3_000) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return false
    }

    @Test("a copy of a link's entry is saved as a link")
    func savedCopyKeepsTheEntrySource() async throws {
        let picker = TestFilePicker()
        let model = makeModel(picker: picker)
        let audio = try temporaryAudio("web")
        defer { try? FileManager.default.removeItem(at: audio) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-saved-web-\(UUID().uuidString).parola")
        defer { try? FileManager.default.removeItem(at: destination) }
        model.libraryEntries = [entry(id: "web", source: .web)]
        model.selectedEntryID = "web"
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")], language: "en", modelName: "stub"
        )
        model.sourceFileURL = audio
        await picker.queueSaveResponse(destination)

        model.saveProjectDocument()

        #expect(await waitForBundle(at: destination))
        #expect(try ParolaDocument.read(at: destination).manifest.source == .web)
    }

    @Test("a copy of something that was never in the library is left to the writer")
    func savedCopyWithoutAnEntryDerivesTheSource() async throws {
        let picker = TestFilePicker()
        let model = makeModel(picker: picker)
        let audio = try temporaryAudio("file")
        defer { try? FileManager.default.removeItem(at: audio) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-saved-file-\(UUID().uuidString).parola")
        defer { try? FileManager.default.removeItem(at: destination) }
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")], language: "en", modelName: "stub"
        )
        model.sourceFileURL = audio
        await picker.queueSaveResponse(destination)

        model.saveProjectDocument()

        #expect(await waitForBundle(at: destination))
        #expect(try ParolaDocument.read(at: destination).manifest.source == .file)
    }
}
