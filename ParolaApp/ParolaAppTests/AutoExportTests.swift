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

    // MARK: - Where a run's exports go

    @MainActor
    private func exportModel(_ name: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(name))
    }

    @MainActor
    private func waitForMarked(_ url: URL) async -> Bool {
        for _ in 0..<300 {
            if OutputMarker.isMarked(url) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return OutputMarker.isMarked(url)
    }

    private func makeFolder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoExportTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let txtEverywhere = [AutoExportRule(sourceExtensions: [], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])]

    @MainActor
    @Test("a take's exports go to the chosen folder under the entry's title, not beside its scratch audio")
    func takeExportsGoToTheFolder() async throws {
        let scratch = try makeFolder("take")
        let chosen = try makeFolder("take-chosen")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: chosen)
        }
        let audio = scratch.appendingPathComponent("parola-recording-\(UUID().uuidString).wav")
        try Data("fake".utf8).write(to: audio)
        let model = exportModel("autoexport-take")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = Self.txtEverywhere

        let entry = try await model.land(RunLanding(
            kind: .recording, transcript: Self.sampleTranscript(), audioSource: audio, source: .microphone,
            title: "Standup 10:30"
        )).value

        let exported = chosen.appendingPathComponent("Standup 10-30.txt")
        #expect(await waitForMarked(exported))
        #expect(OutputMarker.owner(of: exported) == entry.id)
        let beside = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(beside == [audio.lastPathComponent])
        #expect(model.exportNotice == nil)
    }

    @MainActor
    @Test("with no folder chosen, a take and a link skip auto-export and say so once")
    func unsetFolderSkipsWithOneNotice() async throws {
        let model = exportModel("autoexport-unset")
        model.autoExportRules = Self.txtEverywhere
        #expect(model.autoExportFolder == nil)
        #expect(model.defaults.object(forKey: "autoExportFolder") == nil)

        let take = model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Take"
        )
        #expect(take == nil)
        let first = try #require(model.exportNotice)
        #expect(first.offersFolderChoice)
        #expect(first.message.contains("Settings"))

        model.dismissExportNotice()
        model.runAutoExports(transcript: Self.sampleTranscript(), audioSource: nil, source: .web, entry: nil, title: "Link")
        #expect(model.exportNotice == nil, "the reminder comes once a launch")
    }

    @MainActor
    @Test("a chosen folder is kept as a bookmark and is where links land")
    func chosenFolderIsHonored() async throws {
        let chosen = try makeFolder("chosen")
        defer { try? FileManager.default.removeItem(at: chosen) }
        let model = exportModel("autoexport-chosen")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [ExportPreset.builtIn(for: .srt)!.id])]

        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .web, entry: nil, title: "A talk"
        )?.value

        #expect(OutputMarker.isMarked(chosen.appendingPathComponent("A talk.srt")))
        let stored = try #require(model.readJSON(AutoExportFolder.self, forKey: "autoExportFolder"))
        #expect(stored.path == chosen.path)
        #expect(!stored.bookmark.isEmpty)
    }

    @MainActor
    @Test("a moved folder is still found through its bookmark")
    func movedFolderIsFollowed() async throws {
        let chosen = try makeFolder("moved-from")
        let moved = chosen.deletingLastPathComponent().appendingPathComponent("AutoExportTests-moved-to-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: chosen)
            try? FileManager.default.removeItem(at: moved)
        }
        let model = exportModel("autoexport-moved")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = Self.txtEverywhere
        try FileManager.default.moveItem(at: chosen, to: moved)

        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Moved"
        )?.value

        #expect(OutputMarker.isMarked(moved.appendingPathComponent("Moved.txt")))
        #expect(model.exportNotice == nil)
    }

    @MainActor
    @Test("a chosen folder that is gone is not recreated, and says so once")
    func goneFolderSaysSoOnce() async throws {
        let chosen = try makeFolder("gone")
        let model = exportModel("autoexport-gone")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = Self.txtEverywhere
        try FileManager.default.removeItem(at: chosen)

        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Gone"
        )?.value
        let notice = try #require(model.exportNotice)
        #expect(notice.message == ExportNotice.autoExportFolderUnavailable.message)
        #expect(!FileManager.default.fileExists(atPath: chosen.path))

        model.dismissExportNotice()
        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .web, entry: nil, title: "Again"
        )?.value
        #expect(model.exportNotice == nil)
    }

    @MainActor
    @Test("a folder that refuses the write says so once, with the reason")
    func deniedFolderSaysSoOnce() async throws {
        let chosen = try makeFolder("denied")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)
            try? FileManager.default.removeItem(at: chosen)
        }
        let model = exportModel("autoexport-denied")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = Self.txtEverywhere
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: chosen.path)

        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Denied"
        )?.value
        let notice = try #require(model.exportNotice)
        #expect(notice.message.hasPrefix("Auto-export couldn't write to its folder"))

        model.dismissExportNotice()
        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Denied again"
        )?.value
        #expect(model.exportNotice == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)
        #expect(model.setAutoExportFolder(chosen))
        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: nil, source: .microphone, entry: nil, title: "Fixed"
        )?.value
        #expect(OutputMarker.isMarked(chosen.appendingPathComponent("Fixed.txt")))
    }

    @MainActor
    @Test("a file's exports still go beside it, with no folder chosen")
    func fileExportsStayBesideTheSource() async throws {
        let scratch = try makeFolder("file")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = scratch.appendingPathComponent("interview.m4a")
        try Data("fake".utf8).write(to: audio)
        let model = exportModel("autoexport-file")
        model.sweptFolders = { [] }
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["m4a"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])]

        await model.runAutoExports(transcript: Self.sampleTranscript(), audioSource: audio, source: .file, entry: nil)?.value

        #expect(OutputMarker.isMarked(scratch.appendingPathComponent("interview.txt")))
        #expect(model.exportNotice == nil)
    }

    @MainActor
    @Test("a file in a folder that gets cleared, like a Shortcuts input, exports to the chosen folder")
    func sweptFileGoesToTheFolder() async throws {
        let shortcutsInput = try makeFolder("parola-intent")
        let chosen = try makeFolder("swept-chosen")
        defer {
            try? FileManager.default.removeItem(at: shortcutsInput)
            try? FileManager.default.removeItem(at: chosen)
        }
        let audio = shortcutsInput.appendingPathComponent("Recording.m4a")
        try Data("fake".utf8).write(to: audio)
        let model = exportModel("autoexport-swept")
        #expect(model.setAutoExportFolder(chosen))
        model.autoExportRules = Self.txtEverywhere
        #expect(model.sidecarRoute(audioSource: audio, source: .file) == .autoExportFolder)

        await model.runAutoExports(
            transcript: Self.sampleTranscript(), audioSource: audio, source: .file, entry: nil, title: "Voice memo"
        )?.value

        #expect(OutputMarker.isMarked(chosen.appendingPathComponent("Voice memo.txt")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shortcutsInput.path) == ["Recording.m4a"])
    }

    @Test("a swept folder matches through /var and /private/var alike, and only below itself")
    func sweptFolderMatching() {
        let temp = URL(fileURLWithPath: "/var/folders/xy/T", isDirectory: true)
        #expect(AppModel.isInside(URL(fileURLWithPath: "/private/var/folders/xy/T/a/b.wav"), anyOf: [temp]))
        #expect(AppModel.isInside(URL(fileURLWithPath: "/var/folders/xy/T/b.wav"), anyOf: [temp]))
        #expect(!AppModel.isInside(URL(fileURLWithPath: "/var/folders/xy/Tother/b.wav"), anyOf: [temp]))
        #expect(!AppModel.isInside(URL(fileURLWithPath: "/Users/me/Music/b.wav"), anyOf: [temp]))
        let privateTemp = URL(fileURLWithPath: "/private/var/folders/xy/T", isDirectory: true)
        #expect(AppModel.isInside(URL(fileURLWithPath: "/var/folders/xy/T/b.wav"), anyOf: [privateTemp]))
    }
}
