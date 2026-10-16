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

    @Test("with the switch off no summary is written")
    func summaryOff() async throws {
        let rig = try makeRig("summary-off")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try #require(await land(rig, source: .microphone))

        rig.model.summariseOperation = { _, _ in Summary(text: "Quiet") }
        let run = try #require(rig.model.summarise(entry: entry.id, transcript: transcript()))
        _ = try await run.value
        await rig.model.awaitSummaryExports()

        #expect(names(rig.exports).isEmpty)
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
