import Foundation
import Testing
@testable import ParolaCore

@Suite("Export presets")
struct ExportPresetTests {

    @Test("the built-ins cover the seven shipped exports")
    func builtInRoster() {
        #expect(ExportPreset.builtIns.count == 7)
        #expect(ExportPreset.builtIns.filter(\.isBuiltIn).count == 7)
        #expect(ExportPreset.builtIns.map(\.spec.format) == [.txt, .md, .srt, .vtt, .json, .docx, .pdf])
        #expect(ExportPreset.builtIns.map(\.name) == [
            "Transcript (.txt)",
            "Transcript (.md)",
            "Subtitles (.srt)",
            "Subtitles (.vtt)",
            "Segments (.json)",
            "Word (.docx)",
            "PDF",
        ])
    }

    @Test("built-in ids are fixed and unique")
    func builtInIdentifiers() {
        #expect(Set(ExportPreset.builtIns.map(\.id)).count == ExportPreset.builtIns.count)
        #expect(ExportPreset.builtIn(for: .txt)?.id == UUID(uuidString: "E0000000-0000-0000-0000-000000000001"))
        #expect(ExportPreset.builtIn(for: .pdf)?.id == UUID(uuidString: "E0000000-0000-0000-0000-000000000007"))
        #expect(ExportPreset.builtIn(for: .csv) == nil)
    }

    @Test("built-in specs carry the style their format belongs to")
    func builtInStyles() {
        #expect(ExportPreset.builtIn(for: .srt)?.spec.style == .subtitles)
        #expect(ExportPreset.builtIn(for: .json)?.spec.style == .segments)
        #expect(ExportPreset.builtIn(for: .docx)?.spec.style == .transcript)
    }

    @Test("a preset survives a JSON round trip")
    func codableRoundTrip() throws {
        let preset = ExportPreset(
            name: "Reels captions",
            spec: ExportSpec(
                style: .subtitles,
                format: .srt,
                options: ExportOptions(speakers: true, captionLength: .short, grouping: .speakerParagraphs)
            )
        )
        let data = try JSONEncoder().encode([preset])
        let decoded = try JSONDecoder().decode([ExportPreset].self, from: data)
        #expect(decoded == [preset])
    }

    @Test("a spec decodes from a format alone and lands on that format's standard options")
    func specDecodesFromFormatAlone() throws {
        let data = Data(#"{"format":"html"}"#.utf8)
        let spec = try JSONDecoder().decode(ExportSpec.self, from: data)
        #expect(spec == ExportSpec.standard(for: .html))
        #expect(spec.style == .transcript)
        #expect(spec.options.timestamps)
    }

    @Test("standard options match what each format shipped with")
    func standardOptions() {
        #expect(ExportSpec.standard(for: .txt).options.timestamps == false)
        #expect(ExportSpec.standard(for: .txt).options.speakers)
        #expect(ExportSpec.standard(for: .html).options.timestamps)
        #expect(ExportSpec.standard(for: .srt).options.speakers == false)
        #expect(ExportSpec.standard(for: .vtt).options.speakers == false)
        #expect(ExportSpec.standard(for: .srt).options.captionLength == .none)
    }

    @Test("options decode leniently from a partial object")
    func optionsDecodeLeniently() throws {
        let options = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"milliseconds":true}"#.utf8))
        #expect(options.milliseconds)
        #expect(options.speakers)
        #expect(options.grouping == .none)
        #expect(options.content == .original)
        #expect(options.htmlTheme == .light)
    }

    @Test("every format belongs to exactly one style")
    func styleCoversEveryFormat() {
        for format in ExportFormat.allCases {
            let owners = ExportStyle.allCases.filter { $0.formats.contains(format) }
            #expect(owners.count == 1, "\(format.rawValue) should belong to one style")
            #expect(ExportStyle.style(for: format) == owners.first)
        }
    }

    @Test("changing the format moves the spec to that format's style and keeps what it reads")
    func changingFormatMovesTheStyle() {
        let spec = ExportSpec(
            style: .transcript,
            format: .txt,
            options: ExportOptions(timestamps: true, speakers: false, grouping: .speakerParagraphs)
        )
        let moved = spec.changing(format: .vtt)
        #expect(moved.style == .subtitles)
        #expect(moved.options.speakers == false)
        #expect(moved.options.grouping == .speakerParagraphs)
        #expect(moved.options.timestamps == false)
    }

    @Test("changing the style picks that style's first format unless the current one fits")
    func changingStylePicksFormat() {
        let spec = ExportSpec(style: .transcript, format: .md)
        #expect(spec.changing(style: .segments).format == .json)
        #expect(spec.changing(style: .transcript).format == .md)
    }

    @Test("every format has a stable preset id and a preset that names it")
    func formatPresetsCoverEveryFormat() {
        #expect(Set(ExportFormat.allCases.map(ExportPreset.defaultID(for:))).count == ExportFormat.allCases.count)
        for preset in ExportPreset.builtIns {
            #expect(ExportPreset.defaultID(for: preset.spec.format) == preset.id)
        }
        #expect(ExportPreset.formatPreset(for: .csv).name == "CSV")
        #expect(ExportPreset.formatPreset(for: .csv).isBuiltIn == false)
        #expect(ExportPreset.formatPreset(for: .txt) == ExportPreset.builtIn(for: .txt))
        #expect(ExportPreset.formatPresets.count == ExportFormat.allCases.count)
        #expect(ExportPreset.formatPreset(id: ExportPreset.defaultID(for: .lrc))?.name == "LRC Lyrics")
        #expect(ExportPreset.formatPreset(id: UUID()) == nil)
    }

    @Test("changing the format drops the options the new format ignores")
    func changingFormatMasksOptions() {
        var spec = ExportSpec.standard(for: .txt)
        spec.options.timestamps = true
        spec.options.endTimestamps = true
        spec.options.milliseconds = true
        spec.options.speakers = false
        spec.options.grouping = .speakerParagraphs

        let word = spec.changing(format: .docx)
        #expect(word.options.timestamps == false)
        #expect(word.options.endTimestamps == false)
        #expect(word.options.milliseconds == false)
        #expect(word.options.speakers == false)
        #expect(word.options.grouping == .speakerParagraphs)

        let html = spec.changing(format: .html)
        #expect(html.options.timestamps)
        #expect(html.options.htmlTheme == .light)
    }

    @Test("masking keeps the content choice the exporters do not read yet")
    func maskingKeepsContent() {
        var options = ExportOptions()
        options.content = .both
        #expect(options.masked(to: .srt).content == .both)
    }

    @Test("a binary format previews as plain text with the same options")
    func textRenderingOfBinaryFormats() {
        var spec = ExportSpec.standard(for: .docx)
        spec.options.speakers = false
        #expect(spec.textRendering.format == .txt)
        #expect(spec.textRendering.options.speakers == false)
        #expect(spec.textRendering.options.timestamps == false)
        #expect(ExportSpec.standard(for: .srt).textRendering == ExportSpec.standard(for: .srt))
    }

    @Test("timestamp labels follow the end and millisecond options")
    func timestampLabels() {
        #expect(ExportOptions().timestampLabel(start: 5, end: 9) == nil)
        #expect(ExportOptions(timestamps: true).timestampLabel(start: 5, end: 9) == "00:00:05")
        #expect(
            ExportOptions(timestamps: true, endTimestamps: true).timestampLabel(start: 5, end: 9)
                == "00:00:05 → 00:00:09"
        )
        #expect(
            ExportOptions(timestamps: true, milliseconds: true).timestampLabel(start: 5.25, end: 9)
                == "00:00:05.250"
        )
    }
}
