import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Label edits", .timeLimit(.minutes(1)))
struct LabelEditTests {
    let undo = UndoManager()

    private func seededEntry(_ label: String) async throws -> (AppModel, LibraryEntry) {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
        undo.groupsByEvent = false
        model.undoManager = undo
        let entry = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "alpha")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        await model.refreshLibraryAndWait()
        return (model, entry)
    }

    private func labelsOnDisk(_ model: AppModel, _ entry: LibraryEntry) async throws -> [String] {
        try await model.library.load(entry.id).entry.labels
    }

    @Test("two labels added before the first write lands both stick, in the list and on disk")
    func quickAddsBothLand() async throws {
        let (model, entry) = try await seededEntry("labelsburst")

        #expect(model.addLabel("a1", to: entry.id))
        #expect(model.addLabel("b1", to: entry.id))
        #expect(model.labels(for: entry.id) == ["a1", "b1"])

        await model.awaitLabelWrites(for: entry.id)

        #expect(model.pendingLabels[entry.id] == nil)
        #expect(model.libraryEntry(id: entry.id)?.labels == ["a1", "b1"])
        #expect(try await labelsOnDisk(model, entry) == ["a1", "b1"])
    }

    @Test("adds and removes made in one burst land in the order they were made")
    func mixedBurstLandsInOrder() async throws {
        let (model, entry) = try await seededEntry("labelsmixed")

        model.addLabel("a", to: entry.id)
        model.addLabel("b", to: entry.id)
        model.removeLabel("a", from: entry.id)
        model.addLabel("c", to: entry.id)
        #expect(model.labels(for: entry.id) == ["b", "c"])

        await model.awaitLabelWrites(for: entry.id)

        #expect(model.libraryEntry(id: entry.id)?.labels == ["b", "c"])
        #expect(try await labelsOnDisk(model, entry) == ["b", "c"])
    }

    @Test("a label the entry already carries in another casing is refused, even while a write is in flight")
    func duplicateInAnotherCasingIsRefused() async throws {
        let (model, entry) = try await seededEntry("labelsdupe")

        #expect(model.addLabel("Alpha", to: entry.id))
        #expect(model.addLabel("alpha", to: entry.id) == false)
        #expect(model.addLabel("   ", to: entry.id) == false)

        await model.awaitLabelWrites(for: entry.id)

        #expect(try await labelsOnDisk(model, entry) == ["Alpha"])
    }

    @Test("each add and each removal is one undo step, and redo puts it back")
    func eachEditIsOneUndoStep() async throws {
        let (model, entry) = try await seededEntry("labelsundo")

        model.addLabel("a", to: entry.id)
        model.addLabel("b", to: entry.id)
        #expect(undo.undoActionName == "Add Label")

        undo.undo()
        #expect(model.labels(for: entry.id) == ["a"])
        undo.undo()
        #expect(model.labels(for: entry.id) == [])
        undo.redo()
        #expect(model.labels(for: entry.id) == ["a"])

        model.removeLabel("a", from: entry.id)
        #expect(undo.undoActionName == "Remove Label")
        undo.undo()
        #expect(model.labels(for: entry.id) == ["a"])

        await model.awaitLabelWrites(for: entry.id)
        #expect(try await labelsOnDisk(model, entry) == ["a"])
    }

    @Test("undoing a removal reinserts the label where it was, and undoing an add leaves later edits alone")
    func undoIsADeltaNotASnapshot() async throws {
        let (model, entry) = try await seededEntry("labelsdelta")
        model.addLabel("a", to: entry.id)
        model.addLabel("b", to: entry.id)
        model.addLabel("c", to: entry.id)
        model.removeLabel("b", from: entry.id)
        #expect(model.labels(for: entry.id) == ["a", "c"])

        undo.undo()
        #expect(model.labels(for: entry.id) == ["a", "b", "c"])
        undo.redo()
        #expect(model.labels(for: entry.id) == ["a", "c"])
        undo.undo()
        undo.undo()
        #expect(model.labels(for: entry.id) == ["a", "b"])

        await model.awaitLabelWrites(for: entry.id)
        #expect(try await labelsOnDisk(model, entry) == ["a", "b"])
    }

    @Test("undoing an earlier step keeps an edit that was made without an undo step in between")
    func undoKeepsEditsMadeOutOfBand() async throws {
        let (model, entry) = try await seededEntry("labelsoutofband")
        model.addLabel("a", to: entry.id)
        model.undoManager = nil
        model.addLabel("b", to: entry.id)
        model.undoManager = undo

        undo.undo()

        #expect(model.labels(for: entry.id) == ["b"])
        await model.awaitLabelWrites(for: entry.id)
        #expect(try await labelsOnDisk(model, entry) == ["b"])
    }
}
