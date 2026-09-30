import AppKit
import Foundation
import os
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

    /// A board of this suite's own: `.general` is shared with every other pasteboard suite running
    /// in parallel, and with whoever is running the tests.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("export-sheet-test-\(UUID())"))
    }

    @Test("copying renders the spec to the pasteboard")
    func copyWritesThePasteboard() async {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .txt))
        let pasteboard = makePasteboard()

        model.copyExportToPasteboard(pasteboard: pasteboard)

        let copiedTextOnPasteboard = await waitUntil { pasteboard.string(forType: .string) == Self.copiedText }
        #expect(copiedTextOnPasteboard)
    }

    @Test("copying a Word export puts its text on the pasteboard")
    func copyOfABinaryFormatCopiesItsText() async {
        let model = makeModel()
        model.transcript = Self.transcript()
        model.openExportSheet()
        model.setExportSpec(model.exportSheetSpec.changing(format: .docx))
        let pasteboard = makePasteboard()

        model.copyExportToPasteboard(pasteboard: pasteboard)

        let copiedTextOnPasteboard = await waitUntil { pasteboard.string(forType: .string) == Self.copiedText }
        #expect(copiedTextOnPasteboard)
        if case .failed(let message) = model.phase {
            Issue.record("the copy failed: \(message)")
        }
    }

    private static let copiedText = "Ada: Hello world.\nGrace: Goodbye.\n"

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
        #expect(OutputMarker.isMarked(url))
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
    func switchingFormatDropsOptionsItCannotHonour() async throws {
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

    @Test("the preview rendered from a prefix is the whole export's head, in every format")
    func prefixPreviewMatchesTheWholeExport() async throws {
        func transcript(segments count: Int, speakers: [String?]) -> Transcript {
            let segments = (0..<count).map { index in
                TranscriptSegment(
                    id: index,
                    start: Double(index) * 3 + 3500,
                    end: Double(index) * 3 + 2.5 + 3500,
                    text: "Line \(index) of speech, with a comma and some ordinary words.",
                    speaker: speakers[index % speakers.count],
                    words: (0..<3).map {
                        WordTiming(id: "\(index)-\($0)", word: "w\($0)", start: Double(index) * 3, end: Double(index) * 3 + 0.5, probability: 0.9)
                    }
                )
            }
            var transcript = Transcript(segments: segments, language: "en", modelName: "stub", durationSeconds: Double(count) * 3 + 3500)
            transcript.translation = TranscriptTranslation(
                targetLanguage: "it",
                segments: Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, "Riga \($0).") }),
                createdAt: Date(timeIntervalSince1970: 0),
                provider: "test"
            )
            return transcript
        }
        let transcripts = [
            transcript(segments: 1200, speakers: ["Ada", "Ada", "Grace"]),
            transcript(segments: 1200, speakers: [nil]),
            transcript(segments: 150, speakers: ["Ada", nil]),
        ]
        for transcript in transcripts {
            for format in ExportFormat.allCases {
                for grouping in [ExportGrouping.none, .speakerParagraphs] {
                    for content in [ExportContent.original, .both] {
                        var spec = ExportSpec.standard(for: format)
                        spec.options.grouping = grouping
                        spec.options.timestamps = content == .both
                        spec.options.content = content
                        let whole = try Exporters.exporter(for: spec.textRendering).renderText(transcript)
                        let expected = whole.count > ExportPreview.characterCap
                            ? String(whole.prefix(ExportPreview.characterCap)) + "\n…"
                            : whole
                        let preview = try await ExportPreview.render(transcript: transcript, spec: spec)
                        #expect(preview == expected, "\(format) \(grouping) \(content) \(transcript.segments.count)")
                    }
                }
            }
        }
    }

    @Test("a transcript too short to confirm a prefix renders once, in full")
    func shortTranscriptRendersOnce() async throws {
        for count in [150, 300, 399] {
            let segments = (0..<count).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "A line of speech about seventy characters long, give or take a few.")
            }
            let transcript = Transcript(segments: segments, language: "en", modelName: "stub")
            let exporter = CountingExporter(Exporters.exporter(for: .txt))

            let preview = try await ExportPreview.render(transcript: transcript, exporter: exporter)

            #expect(exporter.renders == 1, "\(count) segments")
            let whole = try Exporters.exporter(for: .txt).renderText(transcript)
            #expect(preview == (whole.count > ExportPreview.characterCap ? String(whole.prefix(ExportPreview.characterCap)) + "\n…" : whole))
        }
    }

    @Test("a long transcript confirms its head from two prefixes instead of rendering whole")
    func longTranscriptRendersTwoPrefixes() async throws {
        let segments = (0..<3000).map {
            TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "A line of speech about seventy characters long, give or take a few.")
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "stub")
        let exporter = CountingExporter(Exporters.exporter(for: .txt))

        _ = try await ExportPreview.render(transcript: transcript, exporter: exporter)

        #expect(exporter.renders == 3)
        #expect(exporter.segmentsRendered == 200 + 400 + 800)
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

/// Counts what the preview asks an exporter to render.
private final class CountingExporter: TranscriptExporter {
    private struct Tally {
        var renders = 0
        var segments = 0
    }

    private let inner: any TranscriptExporter
    private let tally = OSAllocatedUnfairLock(initialState: Tally())

    init(_ inner: any TranscriptExporter) { self.inner = inner }

    var format: ExportFormat { inner.format }
    var spec: ExportSpec { inner.spec }
    var renders: Int { tally.withLock { $0.renders } }
    var segmentsRendered: Int { tally.withLock { $0.segments } }

    func encode(_ transcript: Transcript) throws -> Data {
        tally.withLock { $0.renders += 1; $0.segments += transcript.segments.count }
        return try inner.encode(transcript)
    }
}
