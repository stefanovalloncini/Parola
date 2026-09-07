import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("AppModel auto-export")
struct AutoExportTests {

    private static func sampleTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1.2, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.2, end: 2.4, text: "From Parola."),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            durationSeconds: 2.4
        )
    }

    @Test("target filename keeps the source stem and switches the extension")
    func targetFilenameFromSource() {
        let source = URL(fileURLWithPath: "/var/tmp/Some Folder/clip.wav")
        for format in ExportFormat.allCases {
            let target = source.deletingPathExtension().appendingPathExtension(format.fileExtension)
            #expect(target.deletingPathExtension().lastPathComponent == "clip")
            #expect(target.pathExtension == format.fileExtension)
            #expect(target.deletingLastPathComponent() == source.deletingLastPathComponent())
        }
    }

    @Test("target filename preserves dotted stems")
    func targetFilenameDottedStem() {
        let source = URL(fileURLWithPath: "/tmp/note.v2.m4a")
        let target = source.deletingPathExtension().appendingPathExtension("srt")
        #expect(target.lastPathComponent == "note.v2.srt")
    }

    @Test(
        "every export format yields a non-empty exporter for the given format",
        arguments: ExportFormat.allCases
    )
    func formatPicksMatchingExporter(_ format: ExportFormat) throws {
        let exporter = Exporters.exporter(for: format)
        #expect(exporter.format == format)
        let data = try exporter.render(Self.sampleTranscript())
        #expect(data.isEmpty == false)
    }

    @Test("planned formats follow the rule set and ignore disabled rules")
    func plannedFormatsRespectRules() {
        let rules = [
            AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt, .txt]),
            AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.md], enabled: false),
            AutoExportRule(sourceExtensions: ["mp4", "mov"], outputFormats: [.vtt]),
        ]
        let mp4 = AutoExportEngine.plannedFormats(rules: rules, sourceExtension: "mp4")
        #expect(Set(mp4) == [.srt, .txt, .vtt])

        let wav = AutoExportEngine.plannedFormats(rules: rules, sourceExtension: "wav")
        #expect(wav.isEmpty)

        let mov = AutoExportEngine.plannedFormats(rules: rules, sourceExtension: "mov")
        #expect(mov == [.vtt])
    }

    @Test("empty path extension produces no planned formats")
    func emptyExtensionPlansNothing() {
        let url = URL(fileURLWithPath: "/tmp/no_extension")
        let rules = [AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.txt])]
        let formats = AutoExportEngine.plannedFormats(rules: rules, sourceExtension: url.pathExtension)
        #expect(formats.isEmpty)
    }

    @MainActor
    @Test("auto-export rules round-trip through the JSON helpers")
    func rulesRoundTripThroughUserDefaults() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("autoexport"))
        let key = "autoExportTests.rules"

        let written = [
            AutoExportRule(sourceExtensions: ["mp4", "mov"], outputFormats: [.srt, .vtt]),
            AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.txt], enabled: false),
        ]
        model.writeJSON(written, forKey: key)

        let read = model.readJSON([AutoExportRule].self, forKey: key)
        #expect(read?.count == 2)
        #expect(read?.first?.sourceExtensions == ["mp4", "mov"])
        #expect(read?.first?.outputFormats == [.srt, .vtt])
        #expect(read?.last?.enabled == false)
    }

    @MainActor
    @Test("readJSON returns nil when the defaults key is absent")
    func readJSONMissingKey() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("autoexport"))
        let key = "autoExportTests.absent"
        let result = model.readJSON([AutoExportRule].self, forKey: key)
        #expect(result == nil)
    }

    @Test("end-to-end: planned exports write next to the source on disk")
    func writesFilesNextToSource() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("clip.mp4")
        try Data("fake".utf8).write(to: source)

        let rules = [AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.txt, .srt])]
        let formats = AutoExportEngine.plannedFormats(rules: rules, sourceExtension: source.pathExtension)
        for format in formats {
            let target = source.deletingPathExtension().appendingPathExtension(format.fileExtension)
            let data = try Exporters.exporter(for: format).render(Self.sampleTranscript())
            try data.write(to: target, options: .atomic)
        }

        let written = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
        #expect(written == ["clip.mp4", "clip.srt", "clip.txt"])
    }

    @MainActor
    @Test("detached auto-export work runs off the main thread")
    func detachedRunsOffMain() async {
        let ranOffMain = await Task.detached(priority: .utility) {
            pthread_main_np() == 0
        }.value
        #expect(ranOffMain)
    }
}
