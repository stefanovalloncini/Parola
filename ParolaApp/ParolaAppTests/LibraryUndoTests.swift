import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library edits undo and redo", .timeLimit(.minutes(1)))
struct LibraryUndoTests {
    let undo = UndoManager()

    private func makeModel(_ label: String) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
        undo.groupsByEvent = false
        model.undoManager = undo
        return model
    }

    private func add(_ text: String, to model: AppModel, category: EntryCategory = .transcription) async throws -> LibraryEntry {
        try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: category
        )
    }

    @Test("Undo Delete brings the rows back, Redo deletes them again")
    func deleteUndoes() async throws {
        let model = makeModel("undo-delete")
        let first = try await add("first", to: model)
        let second = try await add("second", to: model)
        await model.refreshLibraryAndWait()

        model.deleteEntries([first.id, second.id])
        await waitUntil { model.libraryEntries.isEmpty }
        #expect(undo.undoActionName == "Delete")

        undo.undo()
        await waitUntil { model.libraryEntries.count == 2 }
        #expect(undo.redoActionName == "Delete")

        undo.redo()
        await waitUntil { model.libraryEntries.isEmpty && model.deletedEntries.count == 2 }
    }

    @Test("Undo Restore sends the row back to Recently Deleted")
    func restoreUndoes() async throws {
        let model = makeModel("undo-restore")
        let entry = try await add("kept", to: model)
        try await model.library.delete(entry.id)
        await model.refreshLibraryAndWait()

        model.restoreEntries([entry.id])
        await waitUntil { model.libraryEntry(id: entry.id) != nil }
        #expect(undo.undoActionName == "Restore")

        undo.undo()
        await waitUntil { model.libraryEntry(id: entry.id) == nil && model.deletedEntries.count == 1 }
    }

    @Test("Undo Rename puts back the title and how it was set")
    func renameUndoes() async throws {
        let model = makeModel("undo-rename")
        let entry = try await add("budget", to: model)
        await model.refreshLibraryAndWait()

        model.renameEntry(entry.id, to: "Budget review")
        await waitUntil { model.libraryEntry(id: entry.id)?.manifest.title == "Budget review" }
        #expect(undo.undoActionName == "Rename")

        undo.undo()
        await waitUntil {
            let manifest = model.libraryEntry(id: entry.id)?.manifest
            return manifest?.title == nil && manifest?.titleSource == nil
        }

        undo.redo()
        await waitUntil {
            let manifest = model.libraryEntry(id: entry.id)?.manifest
            return manifest?.title == "Budget review" && manifest?.titleSource == .user
        }
    }

    @Test("Undo Pin unpins only the rows the pin changed")
    func pinUndoes() async throws {
        let model = makeModel("undo-pin")
        let pinned = try await add("pinned", to: model)
        let loose = try await add("loose", to: model)
        try await model.library.setPinned(true, for: pinned.id)
        await model.refreshLibraryAndWait()

        model.setPinned(true, for: [pinned.id, loose.id])
        await waitUntil { model.libraryEntry(id: loose.id)?.pinned == true }
        #expect(undo.undoActionName == "Pin")

        undo.undo()
        await waitUntil { model.libraryEntry(id: loose.id)?.pinned == false }
        #expect(model.libraryEntry(id: pinned.id)?.pinned == true)
        #expect(undo.redoActionName == "Pin")
    }

    @Test("Undo Move puts each row back in its own category")
    func moveUndoes() async throws {
        let model = makeModel("undo-move")
        let meeting = try await add("standup", to: model, category: .meeting)
        let note = try await add("note", to: model, category: .dictation)
        await model.refreshLibraryAndWait()

        model.moveEntries([meeting.id, note.id], to: .transcription)
        await waitUntil { model.libraryEntries.allSatisfy { $0.category == .transcription } }
        #expect(undo.undoActionName == "Move")

        undo.undo()
        await waitUntil {
            model.libraryEntry(id: meeting.id)?.category == .meeting && model.libraryEntry(id: note.id)?.category == .dictation
        }
    }
}
