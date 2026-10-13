import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption wrapper")
struct CaptionWrapperTests {
    @Test("as-is text comes back unchanged")
    func asIsUnchanged() {
        let text = "This is a single line of dialogue without wrapping."
        #expect(CaptionWrapper.asIs(text) == text)
    }

    @Test("as-is text drops a blank line that would split a subtitle cue")
    func asIsDropsBlankLine() {
        #expect(CaptionWrapper.asIs("First part\n\nSecond part") == "First part\nSecond part")
        #expect(CaptionWrapper.asIs("First part\nSecond part") == "First part\nSecond part")
        #expect(CaptionWrapper.asIs("  \n ").isEmpty)
    }

    @Test("srt keeps a segment whose text has a blank line as one cue")
    func srtBlankLineStaysOneCue() throws {
        let transcript = Transcript(
            schemaVersion: 1,
            segments: [
                TranscriptSegment(id: 1, start: 0, end: 2, text: "First part\n\nSecond part"),
                TranscriptSegment(id: 2, start: 2, end: 4, text: "Next cue"),
            ],
            language: "en",
            modelName: "x"
        )
        let raw = try SrtExporter().render(transcript)
        let output = String(data: raw, encoding: .utf8) ?? ""
        let blocks = output
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(blocks.count == 2)
        #expect(blocks[0].hasPrefix("1\n"))
        #expect(blocks[1].hasPrefix("2\n"))
    }

    private func lines(_ text: String, length: CaptionLength, format: ExportFormat = .srt) throws -> [[String]] {
        let transcript = Transcript(segments: [TranscriptSegment(id: 1, start: 0, end: 4, text: text)], language: "en", modelName: "x")
        let output = try Exporters.exporter(for: format == .srt ? .srt(captionLength: length) : .vtt(captionLength: length)).renderText(transcript)
        return output.components(separatedBy: "\n\n").compactMap { block in
            let rows = block.split(separator: "\n").map(String.init).filter { !$0.contains("-->") && $0 != "WEBVTT" && Int($0) == nil }
            return rows.isEmpty ? nil : rows
        }
    }

    @Test("lines stay inside the preset's limit")
    func limits() throws {
        let text = "The quick brown fox jumps over the lazy dog while the cat watches the show."
        for (length, limit) in [(CaptionLength.short, 32), (.medium, 42), (.long, 60)] {
            for cue in try lines(text, length: length) {
                #expect(cue.count <= 2)
                for line in cue { #expect(line.count <= limit) }
            }
        }
    }

    @Test("a word longer than the limit is still emitted on its own line")
    func oversizedWord() throws {
        let cues = try lines("supercalifragilisticexpialidocious is fun", length: .short)
        #expect(cues.flatMap { $0 }.contains("supercalifragilisticexpialidocious"))
    }

    @Test("empty text writes no cue")
    func emptyInput() throws {
        #expect(try lines("   \n  ", length: .short).isEmpty)
    }

    @Test("lines are balanced instead of leaving an orphaned last word (short)")
    func balancesShort() throws {
        #expect(try lines("Hello everyone welcome back today", length: .short) == [["Hello everyone", "welcome back today"]])
    }

    @Test("lines are balanced instead of leaving an orphaned last word (medium)")
    func balancesMedium() throws {
        #expect(try lines("The committee will reconvene tomorrow at noon", length: .medium) == [["The committee will", "reconvene tomorrow at noon"]])
    }
}
