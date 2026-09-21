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

    @Test("formats with real exporter options ask for the sheet, the rest skip it")
    func formatsWithOptions() {
        let withSheet: [ExportFormat] = [.txt, .md, .html, .srt, .vtt]
        let without: [ExportFormat] = [.json, .jsonl, .csv, .tsv, .docx, .pdf, .fcpxml, .lrc]
        for format in withSheet {
            #expect(AppModel.exportHasOptions(format), "\(format.rawValue) should offer options")
        }
        for format in without {
            #expect(!AppModel.exportHasOptions(format), "\(format.rawValue) has no options to offer")
        }
    }

    @Test("exportRequest for an options format opens the sheet instead of queueing the export")
    func exportRequestOpensSheet() {
        let model = makeModel()
        model.transcript = Self.makeTranscript()

        model.exportRequest(.md)

        #expect(model.exportOptionsFormat == .md)
        #expect(model.pendingExport == nil)
    }

    @Test("exportRequest for an option-free format queues the export straight away")
    func exportRequestSkipsSheet() {
        let model = makeModel()
        model.transcript = Self.makeTranscript()

        model.exportRequest(.pdf)

        #expect(model.pendingExport == .pdf)
        #expect(model.exportOptionsFormat == nil)
    }

    @Test("exportRequest without a transcript does nothing")
    func exportRequestNeedsTranscript() {
        let model = makeModel()

        model.exportRequest(.md)
        model.exportRequest(.pdf)

        #expect(model.exportOptionsFormat == nil)
        #expect(model.pendingExport == nil)
    }

    @Test("makeExporter threads the txt timestamps choice into the exporter")
    func makeExporterHonorsTxtTimestamps() {
        let model = makeModel()

        model.txtExportTimestamps = true
        #expect((model.makeExporter(for: .txt) as? TxtExporter)?.options.showTimestamps == true)

        model.txtExportTimestamps = false
        #expect((model.makeExporter(for: .txt) as? TxtExporter)?.options.showTimestamps == false)
    }

    @Test("an explicit includeTimestamps overrides the saved preference in both directions")
    func makeExporterHonorsTimestampOverride() {
        let model = makeModel()

        model.txtExportTimestamps = false
        model.markdownTimestamps = false
        #expect((model.makeExporter(for: .txt, includeTimestamps: true) as? TxtExporter)?.options.showTimestamps == true)
        #expect((model.makeExporter(for: .md, includeTimestamps: true) as? MarkdownExporter)?.options.showTimestamps == true)
        #expect((model.makeExporter(for: .html, includeTimestamps: false) as? HtmlExporter)?.options.showTimestamps == false)

        model.txtExportTimestamps = true
        model.markdownTimestamps = true
        #expect((model.makeExporter(for: .txt, includeTimestamps: false) as? TxtExporter)?.options.showTimestamps == false)
        #expect((model.makeExporter(for: .md, includeTimestamps: false) as? MarkdownExporter)?.options.showTimestamps == false)
        #expect((model.makeExporter(for: .txt) as? TxtExporter)?.options.showTimestamps == true)
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
