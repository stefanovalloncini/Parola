import Foundation
import Testing
@testable import ParolaCore

@Suite("Export options drive the render")
struct ExportOptionsTests {

    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1.5, text: "Hello world.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 61.25, end: 64, text: "Goodbye.", speaker: "Grace"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
            durationSeconds: 64
        )
    }

    private func render(_ format: ExportFormat, _ mutate: (inout ExportOptions) -> Void) throws -> String {
        var spec = ExportSpec.standard(for: format)
        mutate(&spec.options)
        return try Exporters.exporter(for: spec).renderText(sample())
    }

    @Test("the factory builds the exporter the spec names")
    func factoryFollowsTheSpec() {
        for format in ExportFormat.allCases {
            #expect(Exporters.exporter(for: ExportSpec.standard(for: format)).format == format)
        }
    }

    @Test("txt drops speaker labels when speakers are off")
    func txtWithoutSpeakers() throws {
        let out = try render(.txt) { $0.speakers = false }
        #expect(out == "Hello world.\nGoodbye.\n")
    }

    @Test("txt prefixes start times when timestamps are on")
    func txtWithTimestamps() throws {
        let out = try render(.txt) { $0.timestamps = true }
        #expect(out == "[00:00:00] Ada: Hello world.\n[00:01:01] Grace: Goodbye.\n")
    }

    @Test("txt shows a range when end timestamps are on")
    func txtWithEndTimestamps() throws {
        let out = try render(.txt) {
            $0.timestamps = true
            $0.endTimestamps = true
        }
        #expect(out.hasPrefix("[00:00:00 → 00:00:01] Ada: Hello world.\n"))
    }

    @Test("txt shows milliseconds when asked")
    func txtWithMilliseconds() throws {
        let out = try render(.txt) {
            $0.timestamps = true
            $0.milliseconds = true
        }
        #expect(out.hasPrefix("[00:00:00.000] Ada: Hello world.\n"))
        #expect(out.contains("[00:01:01.250] Grace: Goodbye.\n"))
    }

    @Test("markdown drops speaker labels when speakers are off")
    func markdownWithoutSpeakers() throws {
        let out = try render(.md) { $0.speakers = false }
        #expect(out == "# x\n\nHello world.\n\nGoodbye.\n")
    }

    @Test("html honours the theme and drops the timestamp link when timestamps are off")
    func htmlOptions() throws {
        let out = try render(.html) {
            $0.timestamps = false
            $0.htmlTheme = .dark
        }
        #expect(out.contains("background:#111111"))
        #expect(!out.contains("class=\"t\" href="))
        #expect(out.contains("<span class=\"s\">Ada</span>: Hello world."))
    }

    @Test("srt writes the speaker into the cue when speakers are on")
    func srtWithSpeakers() throws {
        let out = try render(.srt) { $0.speakers = true }
        #expect(out.contains("Ada: Hello world."))
    }

    @Test("vtt wraps the cue in a voice tag when speakers are on")
    func vttWithSpeakers() throws {
        let out = try render(.vtt) { $0.speakers = true }
        #expect(out.contains("<v Ada>Hello world.</v>"))
    }

    @Test("caption length wraps a long cue")
    func srtCaptionLength() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "The quick brown fox jumps over the lazy dog again")],
            language: "en",
            modelName: "x"
        )
        var spec = ExportSpec.standard(for: .srt)
        spec.options.captionLength = .short
        let out = try Exporters.exporter(for: spec).renderText(transcript)
        #expect(out.contains("\n"))
        let cueLines = out.split(separator: "\n").filter { !$0.contains("-->") && Int($0) == nil }
        #expect(cueLines.count > 1)
        #expect(cueLines.allSatisfy { $0.count <= 32 })
    }

    @Test("docx drops speaker runs when speakers are off")
    func docxWithoutSpeakers() throws {
        var spec = ExportSpec.standard(for: .docx)
        spec.options.speakers = false
        let data = try Exporters.exporter(for: spec).render(sample())
        let plain = String(decoding: data, as: UTF8.self)
        #expect(!plain.contains("Ada: "))
        #expect(plain.contains("Hello world."))
    }
}
