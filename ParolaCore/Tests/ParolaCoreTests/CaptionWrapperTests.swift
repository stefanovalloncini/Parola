import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption wrapper")
struct CaptionWrapperTests {
    @Test("none preset returns the text unchanged")
    func nonePreset() {
        let text = "This is a single line of dialogue without wrapping."
        let wrapped = CaptionWrapper.wrap(text, length: .none)
        #expect(wrapped == text)
    }

    @Test("short preset caps at 32 chars per line")
    func shortPreset() {
        let text = "The quick brown fox jumps over the lazy dog while the cat watches."
        let wrapped = CaptionWrapper.wrap(text, length: .short)
        for line in wrapped.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.count <= 32)
        }
    }

    @Test("medium preset caps at 42 chars per line")
    func mediumPreset() {
        let text = "The quick brown fox jumps over the lazy dog while the cat watches the show."
        let wrapped = CaptionWrapper.wrap(text, length: .medium)
        for line in wrapped.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.count <= 42)
        }
    }

    @Test("word boundaries are preserved")
    func wordBoundaries() {
        let text = "hello there partner sandwich"
        let wrapped = CaptionWrapper.wrap(text, length: .short)
        for line in wrapped.split(separator: "\n") {
            for char in line {
                #expect(char != "-" && char != "_")
            }
            let words = line.split(separator: " ")
            #expect(words.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("a word longer than the limit is still emitted on its own line")
    func oversizedWord() {
        let text = "supercalifragilisticexpialidocious is fun"
        let wrapped = CaptionWrapper.wrap(text, length: .short)
        let lines = wrapped.split(separator: "\n").map(String.init)
        #expect(lines.contains("supercalifragilisticexpialidocious"))
    }

    @Test("empty input produces empty output")
    func emptyInput() {
        #expect(CaptionWrapper.wrap("", length: .short).isEmpty)
        #expect(CaptionWrapper.wrap("   \n  ", length: .short).isEmpty)
    }

    @Test("none preset drops a blank line that would split a subtitle cue")
    func noneDropsBlankLine() {
        #expect(CaptionWrapper.wrap("First part\n\nSecond part", length: .none) == "First part\nSecond part")
        #expect(CaptionWrapper.wrap("First part\nSecond part", length: .none) == "First part\nSecond part")
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

    @Test("SRT exporter applies the preset to each segment body")
    func exporterApplies() throws {
        let transcript = Transcript(
            schemaVersion: 1,
            segments: [
                TranscriptSegment(
                    id: 1, start: 0, end: 2,
                    text: "The quick brown fox jumps over the lazy dog while the cat watches."
                )
            ],
            language: "en",
            modelName: "x"
        )
        let exporter = SrtExporter(options: SubtitleOptions(captionLength: .short))
        let raw = try exporter.render(transcript)
        let output = String(data: raw, encoding: .utf8) ?? ""
        let bodyLines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst(2)
            .map(String.init)
            .filter { !$0.isEmpty }
        for line in bodyLines {
            #expect(line.count <= 32)
        }
    }
}
