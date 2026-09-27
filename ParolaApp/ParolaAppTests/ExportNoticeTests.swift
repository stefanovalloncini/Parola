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
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "still here")
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
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Solo.md").path))
    }
}
