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
    func previewFollowsTheSpec() async {
        var spec = ExportSpec.standard(for: .txt)
        let plain = await ExportPreview.render(transcript: Self.transcript(), spec: spec)
        #expect(plain == "Ada: Hello world.\nGrace: Goodbye.\n")

        spec.options.timestamps = true
        let timed = await ExportPreview.render(transcript: Self.transcript(), spec: spec)
        #expect(timed.hasPrefix("[00:00:00] Ada: Hello world."))
    }

    @Test("the preview of a binary format shows the text rendering")
    func previewFallsBackForBinaryFormats() async {
        for format in [ExportFormat.docx, .pdf] {
            #expect(ExportPreview.previewSpec(for: .standard(for: format)).format == .txt)
            let text = await ExportPreview.render(transcript: Self.transcript(), spec: .standard(for: format))
            #expect(text.contains("Hello world."))
        }
        #expect(ExportPreview.previewSpec(for: .standard(for: .srt)).format == .srt)
    }

    @Test("the preview stops at the character cap")
    func previewIsCapped() async {
        let segments = (0..<4000).map {
            TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "A long enough line of speech.")
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "stub")

        let text = await ExportPreview.render(transcript: transcript, spec: .standard(for: .txt))

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
