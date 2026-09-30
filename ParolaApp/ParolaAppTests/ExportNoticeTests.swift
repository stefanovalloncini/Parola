import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export notices")
struct ExportNoticeTests {
    private func makeModel(_ picker: TestFilePicker = TestFilePicker()) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            filePicker: picker,
            libraryURL: makeTempLibraryURL("export-notice")
        )
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)], language: "en", modelName: "stub")
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-export-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder that isn't there, so the write throws without a real disk fault.
    private func unwritable(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-export-notice-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test("an export that can't be written says so and leaves the transcript on screen")
    func failedExportKeepsTheTranscript() async {
        let picker = TestFilePicker()
        let model = makeModel(picker)
        model.transcript = transcript("still here")
        model.phase = .ready
        await picker.queueSaveResponse(unwritable("out.txt"))

        model.performExport(.standard(for: .txt))
        await waitUntil { model.exportNotice != nil }

        let notice = model.exportNotice
        #expect(notice?.message.hasPrefix("Export failed:") == true)
        #expect(notice?.succeeded == false)
        #expect(notice?.tone == .failure)
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "still here")
    }

    @Test("a project save that can't be written says so and leaves the transcript on screen")
    func failedDocumentSaveKeepsTheTranscript() async {
        let picker = TestFilePicker()
        let model = makeModel(picker)
        model.transcript = transcript("the open one")
        model.sourceFileURL = URL(fileURLWithPath: "/tmp/parola-notice-source.wav")
        model.phase = .ready
        await picker.queueSaveResponse(unwritable("notes.parola"))

        model.saveProjectDocument()
        await waitUntil { model.exportNotice != nil }

        #expect(model.exportNotice?.succeeded == false)
        #expect(model.exportNotice?.tone == .failure)
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "the open one")
    }

    @Test("a project save that works marks the document as Parola's")
    func savedDocumentIsMarked() async throws {
        let picker = TestFilePicker()
        let model = makeModel(picker)
        model.transcript = transcript("saved")
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("source.wav")
        try Data("RIFFstub".utf8).write(to: audio)
        model.sourceFileURL = audio
        let destination = folder.appendingPathComponent("saved.parola")
        await picker.queueSaveResponse(destination)

        model.saveProjectDocument()
        await waitUntil { OutputMarker.isMarked(destination) || model.exportNotice != nil }

        #expect(OutputMarker.isMarked(destination))
        #expect(model.exportNotice == nil)
    }

    @Test("a term pack that can't be written says so and leaves the transcript on screen")
    func failedTermPackExportKeepsTheTranscript() async {
        let picker = TestFilePicker()
        let model = makeModel(picker)
        model.transcript = transcript("still open")
        model.phase = .ready
        await picker.queueSaveResponse(unwritable("terms.json"))

        model.presentTermPackExporter()
        await waitUntil { model.exportNotice != nil }

        #expect(model.exportNotice?.message.hasPrefix("Export failed:") == true)
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "still open")
    }

    @Test("a notes export that can't be written says so")
    func failedNotesExport() async throws {
        let picker = TestFilePicker()
        let model = makeModel(picker)
        let entry = try await model.library.add(transcript: transcript("with notes"), audioSource: nil)
        await model.refreshLibraryAndWait()
        model.transcript = transcript("with notes")
        model.selectedEntryID = entry.id
        model.phase = .ready
        await picker.queueSaveResponse(unwritable("notes.md"))

        model.exportSegmentNotesAsMarkdown()
        await waitUntil { model.exportNotice != nil }

        #expect(model.exportNotice?.succeeded == false)
        #expect(model.exportNotice?.tone == .failure)
        #expect(model.phase == .ready)
    }

    @Test("a bulk export keeps going past a failure and counts what it wrote")
    func bulkExportKeepsGoing() async throws {
        let model = makeModel()
        var entries: [LibraryEntry] = []
        for title in ["Alpha", "Bravo", "Charlie"] {
            entries.append(try await model.library.add(transcript: transcript(title), audioSource: nil, title: title))
        }
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Bravo.txt"), withIntermediateDirectories: true
        )

        let notice = await model.exportEntries(entries, format: .txt, to: folder)

        #expect(notice.message == "Exported 2 of 3")
        #expect(notice.failures.map(\.name) == ["Bravo"])
        #expect(notice.folder == folder)
        #expect(!notice.succeeded)
        #expect(notice.tone == .failure)
        for written in ["Alpha.txt", "Charlie.txt"] {
            #expect(OutputMarker.isMarked(folder.appendingPathComponent(written)))
        }
    }

    @Test("a bulk export with nothing failed is a success")
    func cleanBulkExport() async throws {
        let model = makeModel()
        let entry = try await model.library.add(transcript: transcript("Solo"), audioSource: nil, title: "Solo")
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let notice = await model.exportEntries([entry], format: .md, to: folder)

        #expect(notice.message == "Exported 1 of 1")
        #expect(notice.succeeded)
        #expect(notice.tone == .success)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Solo.md").path))
    }

    // MARK: - Tone

    @Test("succeeded means a success-tone notice, not just a full folder")
    func succeededMeansSuccessTone() {
        #expect(ExportNotice(message: "m", failures: [], folder: nil, tone: .success).succeeded)
        #expect(!ExportNotice(message: "m", failures: [], folder: nil, tone: .info).succeeded)
        #expect(!ExportNotice(message: "m", failures: [], folder: nil, tone: .failure).succeeded)
    }

    @Test("a plain info or success notice auto-dismisses; one with actions waits to be dismissed or acted on")
    func actionsHoldTheNoticeOpen() {
        let plainInfo = ExportNotice(message: "m", failures: [], folder: nil, tone: .info)
        #expect(plainInfo.autoDismisses)

        let infoWithAction = ExportNotice(
            message: "m", failures: [], folder: nil, tone: .info,
            actions: [ExportNotice.Action(title: "Transcribe", handler: .transcribeEntry("entry-1"))]
        )
        #expect(!infoWithAction.autoDismisses)
    }

    @Test("a failure never auto-dismisses, even without actions")
    func failuresNeverAutoDismiss() {
        let notice = ExportNotice(message: "m", failures: [], folder: nil, tone: .failure)
        #expect(!notice.autoDismisses)
    }

    @Test("a take's notice names the take its buttons act on; other notices name none")
    func takeNoticeNamesItsTake() {
        let take = ExportNotice(
            message: "m", failures: [], folder: nil, tone: .failure,
            actions: [
                ExportNotice.Action(title: "Retry", handler: .retryTake(3)),
                ExportNotice.Action(title: "Show", handler: .showTake(3)),
            ]
        )
        #expect(take.takeID == 3)
        #expect(!take.autoDismisses)
        let entry = ExportNotice(
            message: "m", failures: [], folder: nil, tone: .info,
            actions: [ExportNotice.Action(title: "Open", handler: .openEntry("entry-1"))]
        )
        #expect(entry.takeID == nil)
    }
}
