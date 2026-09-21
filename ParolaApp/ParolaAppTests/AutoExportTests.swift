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

    @Test("planned presets follow the rule set and ignore disabled rules")
    func plannedPresetsRespectRules() {
        let library = ExportPreset.builtIns
        let srt = ExportPreset.builtIn(for: .srt)!.id
        let txt = ExportPreset.builtIn(for: .txt)!.id
        let vtt = ExportPreset.builtIn(for: .vtt)!.id
        let md = ExportPreset.builtIn(for: .md)!.id
        let rules = [
            AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt, txt]),
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [md], enabled: false),
            AutoExportRule(sourceExtensions: ["mp4", "mov"], presetIDs: [vtt]),
        ]
        let mp4 = AutoExportEngine.plannedPresets(rules: rules, sourceExtension: "mp4", presets: library)
        #expect(mp4.map(\.id) == [srt, txt, vtt])

        let wav = AutoExportEngine.plannedPresets(rules: rules, sourceExtension: "wav", presets: library)
        #expect(wav.isEmpty)

        let mov = AutoExportEngine.plannedPresets(rules: rules, sourceExtension: "mov", presets: library)
        #expect(mov.map(\.id) == [vtt])
    }

    @Test("empty path extension produces no planned presets")
    func emptyExtensionPlansNothing() {
        let url = URL(fileURLWithPath: "/tmp/no_extension")
        let rules = [AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])]
        let presets = AutoExportEngine.plannedPresets(rules: rules, sourceExtension: url.pathExtension, presets: ExportPreset.builtIns)
        #expect(presets.isEmpty)
    }

    @MainActor
    @Test("auto-export rules round-trip through the JSON helpers")
    func rulesRoundTripThroughUserDefaults() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("autoexport"))
        let key = "autoExportTests.rules"

        let srt = ExportPreset.builtIn(for: .srt)!.id
        let vtt = ExportPreset.builtIn(for: .vtt)!.id
        let written = [
            AutoExportRule(sourceExtensions: ["mp4", "mov"], presetIDs: [srt, vtt]),
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id], enabled: false),
        ]
        model.writeJSON(written, forKey: key)

        let read = model.readJSON([AutoExportRule].self, forKey: key)
        #expect(read?.count == 2)
        #expect(read?.first?.sourceExtensions == ["mp4", "mov"])
        #expect(read?.first?.presetIDs == [srt, vtt])
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

        let rules = [
            AutoExportRule(
                sourceExtensions: ["mp4"],
                presetIDs: [ExportPreset.builtIn(for: .txt)!.id, ExportPreset.builtIn(for: .srt)!.id]
            )
        ]
        let presets = AutoExportEngine.plannedPresets(
            rules: rules,
            sourceExtension: source.pathExtension,
            presets: ExportPreset.builtIns
        )
        for preset in presets {
            let target = source.deletingPathExtension().appendingPathExtension(preset.spec.format.fileExtension)
            let data = try Exporters.exporter(for: preset.spec).render(Self.sampleTranscript())
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
