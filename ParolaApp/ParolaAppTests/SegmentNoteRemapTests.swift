import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Segment note remap rules")
struct SegmentNoteRemapTests {
    @Test("split keeps the note on the first half")
    func split() {
        #expect(SegmentNoteRemap.afterSplit([0: "keep", 1: "other"], of: 0, into: 20) == [20: "keep", 1: "other"])
        #expect(SegmentNoteRemap.afterSplit([1: "other"], of: 0, into: 20) == [1: "other"])
    }

    @Test("merge keeps the survivor's note and appends the absorbed one")
    func merge() {
        #expect(SegmentNoteRemap.afterMerge([0: "first", 1: "second"], of: 0, with: 1) == [0: "first\n\nsecond"])
        #expect(SegmentNoteRemap.afterMerge([1: "second"], of: 0, with: 1) == [0: "second"])
        #expect(SegmentNoteRemap.afterMerge([0: "first"], of: 0, with: 1) == [0: "first"])
        #expect(SegmentNoteRemap.afterMerge([2: "elsewhere"], of: 0, with: 1) == [2: "elsewhere"])
    }

    @Test("delete drops it")
    func delete() {
        #expect(SegmentNoteRemap.afterDelete([0: "gone", 1: "kept"], of: 0) == [1: "kept"])
    }
}

@MainActor
@Suite("Segment notes follow the edit", .serialized)
struct SegmentNoteEditTests {

    private func loadedModel() async throws -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("segmentnotes")
        )
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 2, text: "hello world"),
                    TranscriptSegment(id: 1, start: 2, end: 4, text: "second segment"),
                ],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        #expect(await waitUntil { model.selectedEntryID == seeded.id && model.transcript != nil })
        // loadEntry ends by stamping the open and refreshing the library; a note patched in before that refresh lands would be overwritten.
        #expect(await waitUntil { model.libraryEntry(id: seeded.id)?.lastOpenedAt != nil })
        await model.libraryRefreshTask?.value
        return model
    }

    private func note(_ model: AppModel, _ text: String, on segmentID: Int) async {
        model.setSegmentNote(text, segmentID: segmentID)
        #expect(await waitUntil { model.currentSegmentNote(for: segmentID) == text })
    }

    @Test("every opening of the note editor starts from the stored note")
    func editorStartsFromTheStoredNote() async throws {
        let model = try await loadedModel()
        let segment = try #require(model.transcript?.segments.first)
        await note(model, "first thought", on: 0)

        model.beginEditingNote(for: segment)
        let first = try #require(model.editingSegmentNote)
        model.editingSegmentNote = nil
        model.beginEditingNote(for: segment)
        let second = try #require(model.editingSegmentNote)

        #expect(first.note == "first thought")
        #expect(second.note == "first thought")
        #expect(first.id != second.id)
    }

    @Test("the note editor writes only while its entry is open and its segment still exists")
    func editorWritesOnlyToItsSegment() {
        let segment = TranscriptSegment(id: 3, start: 0, end: 1, text: "kept")
        let target = SegmentNoteTarget(entryID: "entry", segment: segment, note: nil)
        let others = [TranscriptSegment(id: 4, start: 1, end: 2, text: "other")]

        #expect(SegmentNoteSheet.canWrite(target, entryID: "entry", segments: [segment] + others))
        #expect(!SegmentNoteSheet.canWrite(target, entryID: "entry", segments: others))
        #expect(!SegmentNoteSheet.canWrite(target, entryID: "another", segments: [segment]))
        #expect(!SegmentNoteSheet.canWrite(target, entryID: nil, segments: [segment]))
    }

    @Test("saving and deleting a note are one undo step each, and an unchanged save adds none")
    func noteEditsAreUndoable() async throws {
        let model = try await loadedModel()
        let entryID = try #require(model.selectedEntryID)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        model.setSegmentNote("first", segmentID: 0)
        model.setSegmentNote("  second  ", segmentID: 0)
        model.setSegmentNote("second", segmentID: 0)
        #expect(model.currentSegmentNote(for: 0) == "second")

        undo.undo()
        #expect(model.currentSegmentNote(for: 0) == "first")
        undo.undo()
        #expect(model.currentSegmentNote(for: 0) == nil)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.currentSegmentNote(for: 0) == "first")

        model.setSegmentNote(nil, segmentID: 0)
        #expect(model.currentSegmentNote(for: 0) == nil)
        undo.undo()
        #expect(model.currentSegmentNote(for: 0) == "first")
        #expect(await waitUntil {
            (try? await model.library.load(entryID).entry.segmentNotes) == ["0": "first"]
        })
    }

    @Test("splitting moves the note to the first half, and undo and redo carry it")
    func splitCarriesTheNote() async throws {
        let model = try await loadedModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await note(model, "why this matters", on: 0)

        model.splitSegment(id: 0, atFraction: 0.5)
        let firstHalfID = try #require(model.transcript?.segments.first?.id)
        #expect(firstHalfID != 0)
        #expect(await waitUntil { model.segmentNotesByID == [firstHalfID: "why this matters"] })

        undo.undo()
        #expect(await waitUntil { model.segmentNotesByID == [0: "why this matters"] })

        undo.redo()
        #expect(await waitUntil { model.segmentNotesByID == [firstHalfID: "why this matters"] })
    }

    @Test("merging joins both notes, and deleting drops the one it removed")
    func mergeAndDeleteCarryTheNotes() async throws {
        let model = try await loadedModel()
        await note(model, "first", on: 0)
        await note(model, "second", on: 1)

        model.mergeSegmentWithNext(id: 0)
        #expect(await waitUntil { model.segmentNotesByID == [0: "first\n\nsecond"] })

        model.deleteSegment(id: 0)
        #expect(await waitUntil { model.segmentNotesByID.isEmpty })
    }
}
