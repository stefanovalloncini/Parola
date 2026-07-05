import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Export options sheet routing")
struct ExportOptionsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
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
        let without: [ExportFormat] = [.json, .jsonl, .csv, .tsv, .docx, .pdf]
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
