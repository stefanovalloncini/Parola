import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption cue goldens", .tags(.fileSystem))
struct CaptionCueGoldenTests {
    struct Run: CustomTestStringConvertible, Sendable {
        let name: String
        let format: ExportFormat
        let length: CaptionLength
        var testDescription: String { filename }
        var filename: String { "\(name).\(length.rawValue).\(format.fileExtension)" }
    }

    private static let runs: [Run] = CaptionCueFixtures.cases.flatMap { item -> [Run] in
        let formats: [ExportFormat] = ["speakers", "italian-both", "label-width"].contains(item.name) ? [.srt, .vtt] : [.srt]
        return [CaptionLength.short, .medium, .long].flatMap { length in
            formats.map { Run(name: item.name, format: $0, length: length) }
        }
    }

    private func render(_ run: Run) throws -> String {
        let item = try #require(CaptionCueFixtures.cases.first { $0.name == run.name })
        let exporter = Exporters.exporter(for: CaptionCueFixtures.spec(item, format: run.format, length: run.length))
        return try exporter.renderText(item.transcript)
    }

    @Test("every case reproduces its golden file", arguments: runs)
    func goldenMatches(_ run: Run) throws {
        let actual = try render(run)
        if ProcessInfo.processInfo.environment["PAROLA_REGENERATE_CAPTION_GOLDEN"] != nil {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Resources/caption-golden", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: dir.appendingPathComponent(run.filename))
            return
        }
        let url = try #require(
            Bundle.module.url(forResource: run.filename, withExtension: nil, subdirectory: "caption-golden"),
            "missing golden \(run.filename); run once with PAROLA_REGENERATE_CAPTION_GOLDEN=1"
        )
        #expect(actual == (try String(contentsOf: url, encoding: .utf8)))
    }

    struct AsIsRun: CustomTestStringConvertible, Sendable {
        let name: String
        let format: ExportFormat
        let speakers: Bool
        var testDescription: String { filename }
        var filename: String { "\(name).\(speakers).\(format.fileExtension)" }
    }

    private static let asIsRuns: [AsIsRun] = CaptionCueFixtures.cases.prefix(10).flatMap { item in
        [ExportFormat.srt, .vtt].flatMap { format in
            [false, true].map { AsIsRun(name: item.name, format: format, speakers: $0) }
        }
    }

    @Test("As-is output is byte for byte what the one-cue-per-segment export wrote before cue splitting", arguments: asIsRuns)
    func asIsMatchesBeforeSplitting(_ run: AsIsRun) throws {
        let item = try #require(CaptionCueFixtures.cases.first { $0.name == run.name })
        var spec = CaptionCueFixtures.spec(item, format: run.format, length: .none)
        spec.options.speakers = run.speakers
        let actual = try Exporters.exporter(for: spec).renderText(item.transcript)
        let url = try #require(Bundle.module.url(forResource: run.filename, withExtension: nil, subdirectory: "caption-golden/as-is"))
        #expect(actual == (try String(contentsOf: url, encoding: .utf8)))
    }
}
