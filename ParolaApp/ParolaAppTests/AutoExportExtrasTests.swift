import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Auto-Export extras", .serialized)
struct AutoExportExtrasTests {

    private struct Rig {
        let model: AppModel
        let root: URL
        let exports: URL
        let audio: URL
    }

    private func makeRig(_ label: String, recording: Bool = false, summary: Bool = false) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-extras-\(label)-\(UUID().uuidString)", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("take.wav")
        try Data(repeating: 7, count: 4096).write(to: audio)
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("extras-\(label)"), features: Set(ParolaFeature.allCases)
        )
        model.completionSoundPlayer = {}
        model.playSoundWhenFinished = false
        model.cardMetadataOperation = { _ in CardMetadata(title: "Titled", summary: "Summed up.") }
        model.sweptFolders = { [] }
        model.autoExportRecording = recording
        model.autoExportSummary = summary
        #expect(model.setAutoExportFolder(exports))
        return Rig(model: model, root: root, exports: exports, audio: audio)
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func transcript() -> Transcript {
        Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello there")], language: "en", modelName: "stub")
    }

    private func storedSummary(_ rig: Rig, _ id: LibraryEntry.ID) async -> String? {
        try? await rig.model.library.load(id).document.transcript.summary?.text
    }

    private func land(_ rig: Rig, source: EntrySource, title: String = "Weekly sync") async -> LibraryEntry? {
        let landing = RunLanding(
            kind: source == .file ? .file : .recording, transcript: transcript(), audioSource: rig.audio,
            source: source, category: source == .systemAudio ? .meeting : .transcription, title: title
        )
        let entry = try? await rig.model.land(landing).value
        await rig.model.awaitLandingSteps()
        return entry
    }

    @Test("a take's audio is copied to the Auto-Export folder under its title, in its stored format")
    func recordingIsCopied() async throws {
        let rig = try makeRig("recording", recording: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let entry = await land(rig, source: .microphone)

        #expect(entry != nil)
        #expect(names(rig.exports) == ["Weekly sync.wav"])
        let copy = rig.exports.appendingPathComponent("Weekly sync.wav")
        #expect(try Data(contentsOf: copy) == Data(contentsOf: rig.audio))
        #expect(OutputMarker.isMarked(copy))
    }

    @Test("a meeting is copied too, and a copy of the same take replaces its own file")
    func meetingAndRerun() async throws {
        let rig = try makeRig("meeting", recording: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let entry = try #require(await land(rig, source: .systemAudio, title: "Board call"))
        await rig.model.exportRecording(of: entry, source: .systemAudio)?.value
        await rig.model.exportRecording(of: entry, source: .systemAudio)?.value

        #expect(names(rig.exports) == ["Board call.wav"])
    }

    @Test("an imported file is not copied")
    func importedFileStays() async throws {
        let rig = try makeRig("imported", recording: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }

        _ = await land(rig, source: .file)

        #expect(names(rig.exports).isEmpty)
    }

    @Test("with the switch off nothing is copied")
    func recordingOff() async throws {
        let rig = try makeRig("recording-off")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        _ = await land(rig, source: .microphone)

        #expect(names(rig.exports).isEmpty)
    }

    @Test("a file already there that the export did not write is kept, and the copy is numbered")
    func neverOverwritesForeignFiles() async throws {
        let rig = try makeRig("foreign", recording: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let theirs = rig.exports.appendingPathComponent("Weekly sync.wav")
        try Data("mine".utf8).write(to: theirs)

        _ = await land(rig, source: .microphone)

        #expect(names(rig.exports) == ["Weekly sync (2).wav", "Weekly sync.wav"])
        #expect(try Data(contentsOf: theirs) == Data("mine".utf8))
    }

    @Test("a summary that finishes after the transcript's export is written when it lands")
    func lateSummary() async throws {
        let rig = try makeRig("late-summary", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        #expect(names(rig.exports).isEmpty)

        rig.model.summariseOperation = { _, _ in Summary(text: "- First point\n- Second point") }
        rig.model.summarise(entry: entry.id, transcript: transcript())
        let target = rig.exports.appendingPathComponent("Weekly sync – Summary.md")
        await waitUntil(timeoutMs: 10_000) { FileManager.default.fileExists(atPath: target.path) }
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports) == ["Weekly sync – Summary.md"])
        #expect(try String(contentsOf: target, encoding: .utf8) == "- First point\n- Second point\n")
        #expect(OutputMarker.isMarked(target))
    }

    @Test("a regenerated summary replaces the file the export wrote, and only that one")
    func regeneratedSummary() async throws {
        let rig = try makeRig("regenerate", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        let target = rig.exports.appendingPathComponent("Weekly sync – Summary.md")

        rig.model.summariseOperation = { _, _ in Summary(text: "First") }
        rig.model.summarise(entry: entry.id, transcript: transcript())
        await waitUntil(timeoutMs: 10_000) { FileManager.default.fileExists(atPath: target.path) }
        await rig.model.awaitSummaryExports()

        rig.model.summariseOperation = { _, _ in Summary(text: "Second") }
        rig.model.summarise(entry: entry.id, transcript: transcript())
        await waitUntil(timeoutMs: 10_000) { (try? String(contentsOf: target, encoding: .utf8)) == "Second\n" }
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports) == ["Weekly sync – Summary.md"])
    }

    @Test("a summary file somebody else wrote is kept and the export is numbered")
    func foreignSummaryFile() async throws {
        let rig = try makeRig("foreign-summary", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        let theirs = rig.exports.appendingPathComponent("Weekly sync – Summary.md")
        try Data("theirs".utf8).write(to: theirs)

        rig.model.summariseOperation = { _, _ in Summary(text: "Ours") }
        rig.model.summarise(entry: entry.id, transcript: transcript())
        let numbered = rig.exports.appendingPathComponent("Weekly sync (2) – Summary.md")
        await waitUntil(timeoutMs: 10_000) { FileManager.default.fileExists(atPath: numbered.path) }
        await rig.model.awaitSummaryExports()

        #expect(try String(contentsOf: theirs, encoding: .utf8) == "theirs")
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "Ours\n")
    }

    @Test("with the switch off no summary is written, though the summary lands")
    func summaryOff() async throws {
        let rig = try makeRig("summary-off")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))

        rig.model.summariseOperation = { _, _ in Summary(text: "Quiet") }
        rig.model.summarise(entry: entry.id, transcript: transcript())
        await waitUntil(timeoutMs: 10_000) { await storedSummary(rig, entry.id) == "Quiet" }
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports).isEmpty)
    }

    @Test("a chat's digest becomes the entry's summary and gets its file too")
    func chatDigestIsExported() async throws {
        let rig = try makeRig("digest", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        rig.model.summariseOperation = { _, _ in Summary(text: "The digest") }

        _ = try await rig.model.chatDigest(for: entry.id, transcript: transcript())()
        let target = rig.exports.appendingPathComponent("Weekly sync – Summary.md")
        await waitUntil(timeoutMs: 10_000) { FileManager.default.fileExists(atPath: target.path) }
        await rig.model.awaitSummaryExports()

        #expect(try String(contentsOf: target, encoding: .utf8) == "The digest\n")
    }

    @Test("summaries land in the order they were queued, so the newest text is the file")
    func summariesAreWrittenInOrder() async throws {
        let rig = try makeRig("order", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))

        for round in 1...6 { rig.model.queueSummaryExport(Summary(text: "Version \(round)"), of: entry.id) }
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports) == ["Weekly sync – Summary.md"])
        #expect(try String(contentsOf: rig.exports.appendingPathComponent("Weekly sync – Summary.md"), encoding: .utf8) == "Version 6\n")
    }

    @Test("a renamed entry's regenerated summary replaces the old file instead of leaving two")
    func renamedEntryKeepsOneSummaryFile() async throws {
        let rig = try makeRig("renamed", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        rig.model.queueSummaryExport(Summary(text: "First"), of: entry.id)
        await rig.model.awaitSummaryExports()
        #expect(names(rig.exports) == ["Weekly sync – Summary.md"])

        try await rig.model.library.renameEntry(entry.id, to: "Board call")
        rig.model.queueSummaryExport(Summary(text: "Second"), of: entry.id)
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports) == ["Board call – Summary.md"])
    }

    @Test("a summary file the user edited is kept, and the next summary goes into a numbered copy")
    func editedSummaryIsTheUsers() async throws {
        let rig = try makeRig("edited", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        rig.model.queueSummaryExport(Summary(text: "First"), of: entry.id)
        await rig.model.awaitSummaryExports()
        let file = rig.exports.appendingPathComponent("Weekly sync – Summary.md")
        try Data("My own notes on top\n".utf8).write(to: file)

        rig.model.queueSummaryExport(Summary(text: "Second"), of: entry.id)
        await rig.model.awaitSummaryExports()

        #expect(try String(contentsOf: file, encoding: .utf8) == "My own notes on top\n")
        #expect(try String(contentsOf: rig.exports.appendingPathComponent("Weekly sync (2) – Summary.md"), encoding: .utf8) == "Second\n")
    }

    @Test("a copy that fails after its staging file exists leaves no hidden partial file behind")
    func failedCopyLeavesNothing() async throws {
        let rig = try makeRig("failed-copy")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let blocker = rig.exports.appendingPathComponent("Weekly sync.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: blocker.appendingPathComponent("keep.txt"))
        OutputMarker.mark(blocker, owner: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocker.path) }

        await #expect(throws: (any Error).self) {
            try await AppModel.copyOwned(rig.audio, into: rig.exports, named: "Weekly sync", tail: "", owner: "x")
        }

        let left = (try? FileManager.default.contentsOfDirectory(atPath: rig.exports.path)) ?? []
        #expect(left == ["Weekly sync.wav"])
    }

    @Test("a summary file the user renamed or duplicated without editing it is never removed")
    func renamedOrDuplicatedSummaryStays() async throws {
        let rig = try makeRig("renamed-copy", summary: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))
        rig.model.queueSummaryExport(Summary(text: "First"), of: entry.id)
        await rig.model.awaitSummaryExports()
        let original = rig.exports.appendingPathComponent("Weekly sync – Summary.md")
        let duplicate = rig.exports.appendingPathComponent("Weekly sync – Summary copy.md")
        let renamed = rig.exports.appendingPathComponent("Weekly sync – first draft.md")
        try FileManager.default.copyItem(at: original, to: duplicate)
        try FileManager.default.moveItem(at: original, to: renamed)

        rig.model.queueSummaryExport(Summary(text: "Second"), of: entry.id)
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports) == ["Weekly sync – Summary copy.md", "Weekly sync – Summary.md", "Weekly sync – first draft.md"])
        #expect(try String(contentsOf: duplicate, encoding: .utf8) == "First\n")
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "First\n")
        #expect(try String(contentsOf: original, encoding: .utf8) == "Second\n")
    }

    @Test("deleting a preset takes it out of the watched folders that name it")
    func deletedPresetLeavesTheFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-extras-prune-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("extras-prune"))
        let custom = model.addExportPreset(name: "Short SRT", spec: ExportPreset.builtIn(for: .srt)!.spec)
        var options = WatchedFolderOptions()
        options.exportPresetIDs = [custom.id]
        options.savesToLibrary = false
        let bookmark = try inbox.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = WatchedFolder(bookmark: bookmark, displayPath: inbox.path, options: options)
        defaults.set(try JSONEncoder().encode([folder]), forKey: "watchedFolders")
        let store = model.watchedFolders
        #expect(model.exportPresetUse(id: custom.id).folderCount == 1)
        #expect(model.exportPresetUse(id: custom.id).soleFormatFolderCount == 1)

        model.deleteExportPreset(id: custom.id)

        #expect(store.options(for: folder.id).exportPresetIDs.isEmpty)
        #expect(store.options(for: folder.id).savesToLibrary)
        await store.stopWatching()
    }

    @Test("Choose… in Auto-Export takes the folder the picker returns")
    func chooseFolderThroughThePicker() async throws {
        let picker = TestFilePicker()
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), filePicker: picker, libraryURL: makeTempLibraryURL("extras-picker")
        )
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("parola-extras-chosen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }

        await model.chooseAutoExportFolderFromPanel()
        #expect(model.autoExportFolder == nil)

        await picker.queueFolderResponse(chosen)
        await model.chooseAutoExportFolderFromPanel()
        #expect(model.autoExportFolder?.path == chosen.path)
    }

    @Test("both extras are off by default, are saved, and belong to the Auto-Export pane's reset")
    func defaultsAndKeys() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("extras-keys"))
        #expect(!model.autoExportRecording)
        #expect(!model.autoExportSummary)
        model.autoExportRecording = true
        #expect(model.defaults.bool(forKey: "autoExportRecording"))
        let keys = SettingsPaneScope.autoExport.resetKeys(features: .all)
        #expect(keys.contains("autoExportRecording") && keys.contains("autoExportSummary"))
    }
}
