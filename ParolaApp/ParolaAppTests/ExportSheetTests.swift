import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export sheet", .serialized)
struct ExportSheetTests {

    private func makeModel(picker: TestFilePicker? = nil) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            filePicker: picker ?? TestFilePicker(),
            libraryURL: makeTempLibraryURL("export-sheet")
        )
    }

    private static func transcript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Goodbye.", speaker: "Grace"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("the sheet only opens with a transcript loaded")
    func openNeedsATranscript() {
        let model = makeModel()

        model.openExportSheet()
        #expect(model.exportSheetOpen == false)

        model.transcript = Self.transcript()
        model.openExportSheet()
        #expect(model.exportSheetOpen)
        #expect(model.exportSheetSpec.format == model.exportPresets.first?.spec.format)
    }

    @Test("setting a format moves the spec to that format's style")
    func settingFormatFollowsTheStyle() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()

        model.setExportSpec(model.exportSheetSpec.changing(format: .vtt))

        #expect(model.exportSheetSpec.format == .vtt)
        #expect(model.exportSheetSpec.style == .subtitles)
    }

    @Test("a spec whose format does not belong to its style is repaired")
    func settingSpecRepairsTheStyle() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()

        model.setExportSpec(ExportSpec(style: .segments, format: .srt))

        #expect(model.exportSheetSpec.style == .subtitles)
        #expect(model.exportSheetSpec.format == .srt)
    }

    @Test("exporting from the sheet closes it and queues the spec")
    func exportQueuesTheSpec() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .srt))

        model.exportFromSheet()

        #expect(model.exportSheetOpen == false)
        #expect(model.pendingExport?.format == .srt)
    }

    @Test("Export As queues the preset's spec")
    func exportWithPresetQueuesItsSpec() {
        let model = makeModel()
        model.transcript = Self.transcript()
        let json = ExportPreset.builtIn(for: .json)!

        model.exportWithPreset(json.id)

        #expect(model.pendingExport == json.spec)
    }

    @Test("copying renders the spec to the pasteboard")
    func copyWritesThePasteboard() async throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .txt))

        NSPasteboard.general.clearContents()
        model.copyExportToPasteboard()

        var text: String?
        for _ in 0..<200 {
            text = NSPasteboard.general.string(forType: .string)
            if text == "Ada: Hello world.\nGrace: Goodbye.\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(text == "Ada: Hello world.\nGrace: Goodbye.\n")
    }

    @Test("copying a Word export puts its text on the pasteboard")
    func copyOfABinaryFormatCopiesItsText() async throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .docx))

        NSPasteboard.general.clearContents()
        model.copyExportToPasteboard()

        var text: String?
        for _ in 0..<200 {
            text = NSPasteboard.general.string(forType: .string)
            if text == "Ada: Hello world.\nGrace: Goodbye.\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(text == "Ada: Hello world.\nGrace: Goodbye.\n")
        #expect(model.phase != .failed(message: ""))
    }

    @Test("the sheet reopens on the spec it was left on")
    func sheetRemembersTheSessionSpec() {
        let model = makeModel()
        model.transcript = Self.transcript()

        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .srt))
        model.closeExportSheet()

        model.openExportSheet()

        #expect(model.exportSheetSpec.format == .srt)
        #expect(model.exportSheetSpec.style == .subtitles)
    }

    @Test("the quick export shortcut still writes the first preset")
    func firstPresetIsTheQuickExport() throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        let first = try #require(model.exportPresets.first)

        model.exportWithPreset(first.id)

        #expect(first.spec.format == .txt)
        #expect(model.pendingExport == first.spec)
    }

    @Test("saving the sheet's spec adds a preset with that spec")
    func saveAsPresetKeepsTheSpec() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        var spec = ExportSpec.standard(for: .srt)
        spec.options.captionLength = .short
        model.setExportSpec(spec)

        model.saveExportSheetSpecAsPreset(name: "Reels")

        #expect(model.exportPresets.last?.name == "Reels")
        #expect(model.exportPresets.last?.spec.options.captionLength == .short)
    }

    @Test("a blank preset name is refused")
    func saveAsPresetNeedsAName() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        let before = model.exportPresets.count

        model.saveExportSheetSpecAsPreset(name: "   ")

        #expect(model.exportPresets.count == before)
    }

    @Test("exporting to a path writes the spec's bytes")
    func exportToPathWritesTheFile() async throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-export-sheet-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await model.exportTranscript(spec: .standard(for: .srt), to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("00:00:00,000 --> 00:00:01,000"))
    }

    @Test("the preview follows the spec")
    func previewFollowsTheSpec() async throws {
        var spec = ExportSpec.standard(for: .txt)
        let plain = try await ExportPreview.render(transcript: Self.transcript(), spec: spec)
        #expect(plain == "Ada: Hello world.\nGrace: Goodbye.\n")

        spec.options.timestamps = true
        let timed = try await ExportPreview.render(transcript: Self.transcript(), spec: spec)
        #expect(timed.hasPrefix("[00:00:00] Ada: Hello world."))
    }

    @Test("the preview of a binary format shows the text rendering")
    func previewFallsBackForBinaryFormats() async throws {
        for format in [ExportFormat.docx, .pdf] {
            #expect(ExportSpec.standard(for: format).textRendering.format == .txt)
            let text = try await ExportPreview.render(transcript: Self.transcript(), spec: .standard(for: format))
            #expect(text.contains("Hello world."))
        }
        #expect(ExportSpec.standard(for: .srt).textRendering.format == .srt)
    }

    @Test("switching to a binary format drops the options it cannot honour")
    func binaryFormatPreviewMatchesTheFile() async throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()

        var timestamped = model.exportSheetSpec
        timestamped.options.timestamps = true
        model.setExportSpec(timestamped)
        #expect(model.exportSheetSpec.options.timestamps)

        model.setExportSpec(model.exportSheetSpec.changing(format: .docx))

        #expect(model.exportSheetSpec.options.timestamps == false)
        let preview = try await ExportPreview.render(transcript: Self.transcript(), spec: model.exportSheetSpec)
        #expect(preview.hasPrefix("Ada: Hello world."))
        #expect(!preview.contains("[00:00:00]"))
    }

    @Test("the preview stops at the character cap")
    func previewIsCapped() async throws {
        let segments = (0..<4000).map {
            TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "A long enough line of speech.")
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "stub")

        let text = try await ExportPreview.render(transcript: transcript, spec: .standard(for: .txt))

        #expect(text.count <= ExportPreview.characterCap + 2)
    }

    @Test("a merged spec follows the field the caller named")
    func mergedSpecFollowsTheNamedField() throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()

        let byFormat = try model.mergedExportSpec(overriding: ["format": .string("srt")])
        #expect(byFormat.format == .srt)
        #expect(byFormat.style == .subtitles)

        let byStyle = try model.mergedExportSpec(overriding: ["style": .string("segments")])
        #expect(byStyle.style == .segments)
        #expect(byStyle.format == .json)

        let byOption = try model.mergedExportSpec(overriding: ["options": .object(["timestamps": .bool(true)])])
        #expect(byOption.format == model.exportSheetSpec.format)
        #expect(byOption.options.timestamps)
        #expect(byOption.options.speakers == model.exportSheetSpec.options.speakers)
    }

    @Test("an options-only merge is masked the way setExportSpec masks")
    func mergedSpecMasksAnOptionsOnlyOverride() throws {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(.standard(for: .srt))

        let merged = try model.mergedExportSpec(overriding: ["options": .object(["timestamps": .bool(true)])])

        #expect(merged.format == .srt)
        #expect(merged.options.timestamps == false, "srt cannot honour timestamps, and exportWithSpec must drop them the way setExportSpec does")
        #expect(merged == merged.changing(format: merged.format))
    }

    @Test("a merged spec that decodes to nothing is refused")
    func mergedSpecRefusesGarbage() {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()

        #expect(throws: AutomationError.self) {
            _ = try model.mergedExportSpec(overriding: ["format": .string("wav")])
        }
    }

    @Test("every format lists the options it honours")
    func optionFieldsPerFormat() {
        #expect(ExportFormat.txt.optionFields.contains(.timestamps))
        #expect(ExportFormat.txt.optionFields.contains(.htmlTheme) == false)
        #expect(ExportFormat.html.optionFields.contains(.htmlTheme))
        #expect(ExportFormat.srt.optionFields.contains(.captionLength))
        #expect(ExportFormat.srt.optionFields.contains(.timestamps) == false)
        #expect(ExportFormat.json.optionFields == [.grouping])
        for format in ExportFormat.allCases {
            #expect(format.optionFields.contains(.grouping), "\(format.rawValue) should offer grouping")
        }
    }
}
