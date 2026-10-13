import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
final class CascadeGate {
    var open = false
}

@MainActor
@Suite("People cascades across the library")
struct PeopleCascadeTests {

    /// Two entries, both assigned to the same person, with the first one open.
    private func makeTwoAssignedEntries(
        _ label: String,
        secondPerson: String? = nil
    ) async throws -> (model: AppModel, open: LibraryEntry, other: LibraryEntry) {
        let model = PeopleTestSupport.makeModel(label)
        let first = try await PeopleTestSupport.seed(model, text: "first")
        let second = try await PeopleTestSupport.seed(model, text: "second")

        try await PeopleTestSupport.open(model, entry: second)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: secondPerson ?? "Ada")

        try await PeopleTestSupport.open(model, entry: first)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        return (model, first, second)
    }

    private func storedSpeakers(_ model: AppModel, _ id: LibraryEntry.ID) async throws -> [String?] {
        try await model.library.load(id).document.transcript.segments.map(\.speaker)
    }

    @Test("renaming a person rewrites both entries and re-keys their maps")
    func renameCascades() async throws {
        let (model, open, other) = try await makeTwoAssignedEntries("cascaderename")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.renamePerson(ada.id, to: "Ada Lovelace")

        #expect(model.transcript?.segments.map(\.speaker) == ["Ada Lovelace", "SPEAKER_01", "Ada Lovelace"])
        #expect(model.libraryEntry(id: open.id)?.speakerAssignments == ["Ada Lovelace": ada.id])
        #expect(model.libraryEntry(id: other.id)?.speakerAssignments == ["Ada Lovelace": ada.id])
        #expect(try await storedSpeakers(model, other.id) == ["Ada Lovelace", "SPEAKER_01", "Ada Lovelace"])
        #expect(model.people.map(\.name) == ["Ada Lovelace"])
    }

    @Test("a rename is one undo step: undo names them back everywhere, redo renames again")
    func renameUndoesAsOneStep() async throws {
        let (model, open, other) = try await makeTwoAssignedEntries("cascadeundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.renamePerson(ada.id, to: "Ada Lovelace")
        #expect(undo.undoActionName == "Rename Person")

        undo.undo()
        #expect(!undo.canUndo)
        #expect(undo.redoActionName == "Rename Person")
        #expect(await waitUntil {
            let stored = try? await storedSpeakers(model, other.id)
            return model.people.map(\.name) == ["Ada"]
                && model.transcript?.segments.map(\.speaker) == ["Ada", "SPEAKER_01", "Ada"]
                && model.libraryEntry(id: open.id)?.speakerAssignments == ["Ada": ada.id]
                && model.libraryEntry(id: other.id)?.speakerAssignments == ["Ada": ada.id]
                && stored == ["Ada", "SPEAKER_01", "Ada"]
        })

        undo.redo()
        #expect(undo.undoActionName == "Rename Person")
        #expect(await waitUntil {
            let stored = try? await storedSpeakers(model, other.id)
            return model.people.map(\.name) == ["Ada Lovelace"]
                && model.transcript?.segments.first?.speaker == "Ada Lovelace"
                && stored == ["Ada Lovelace", "SPEAKER_01", "Ada Lovelace"]
        })
    }

    @Test("two undos right after an assign and a rename leave no dangling assignment")
    func doubleUndoAfterAssignAndRename() async throws {
        let model = PeopleTestSupport.makeModel("cascadelifo")
        let entry = try await PeopleTestSupport.openSeededEntry(model)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        await model.renamePerson(ada.id, to: "Ada Lovelace")

        undo.undo()
        undo.undo()

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        #expect(model.speakerAssignments.isEmpty)
        await model.awaitSpeakerAssignmentWrites()
        await model.personRenameTask?.value
        await model.awaitSpeakerAssignmentWrites()
        #expect(model.speakerAssignments.isEmpty)
        #expect(try await model.library.load(entry.id).entry.speakerAssignments.isEmpty)
        #expect(model.people.map(\.name) == ["Ada"])
    }

    @MainActor
    private final class FirstWrite {
        var landed = false
    }

    @Test("a cascade that reads the listing between two undo writes can't re-add the cleared assignment")
    func cascadeReadingStaleListingAfterDoubleUndo() async throws {
        let model = PeopleTestSupport.makeModel("cascadestale")
        let entry = try await PeopleTestSupport.openSeededEntry(model)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        await model.renamePerson(ada.id, to: "Ada Lovelace")

        let firstWrite = FirstWrite()
        model.personRenameCascadeHook = { [unowned model] in
            model.personRenameCascadeHook = nil
            await waitUntil { firstWrite.landed }
        }
        model.speakerAssignmentWriteHook = { [unowned model] in
            model.speakerAssignmentWriteHook = nil
            firstWrite.landed = true
            await waitUntil { model.people.map(\.name) == ["Ada"] }
        }
        undo.undo()
        undo.undo()
        await model.awaitSpeakerAssignmentWrites()
        await model.personRenameTask?.value
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.speakerAssignments.isEmpty)
        #expect(try await model.library.load(entry.id).entry.speakerAssignments.isEmpty)
    }

    @Test("undoing a rename puts an entry back under the label it carried, even when entries differed")
    func undoRestoresEachEntrysOwnLabel() async throws {
        let (model, _, other) = try await makeTwoAssignedEntries("cascadelabels")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        try await model.library.mutateTranscript(for: other.id) { stored in
            stored = stored.renamingSpeaker("Ada", to: "Dr Ada")
        }
        _ = try await model.library.mutateSpeakerAssignments(for: other.id) { $0 = ["Dr Ada": ada.id] }
        await model.library.dropCaches()
        await model.refreshLibraryAndWait()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        await model.renamePerson(ada.id, to: "Ada Lovelace")
        #expect(try await storedSpeakers(model, other.id) == ["Ada Lovelace", "SPEAKER_01", "Ada Lovelace"])

        undo.undo()
        #expect(await waitUntil {
            let stored = try? await storedSpeakers(model, other.id)
            return stored == ["Dr Ada", "SPEAKER_01", "Dr Ada"]
                && model.libraryEntry(id: other.id)?.speakerAssignments == ["Dr Ada": ada.id]
                && model.people.map(\.name) == ["Ada"]
        })
        #expect(model.transcript?.segments.first?.speaker == "Ada")
    }

    private func assertNoDanglingAssignments(_ model: AppModel) async throws {
        let known = Set(model.people.map(\.id))
        #expect(Set(model.speakerAssignments.values).isSubset(of: known))
        for entry in model.libraryEntries {
            #expect(Set(entry.speakerAssignments.values).isSubset(of: known))
        }
    }

    @Test("undoing a rename does nothing once the old name belongs to another person")
    func undoIntoATakenNameChangesNothing() async throws {
        let (model, _, _) = try await makeTwoAssignedEntries("cascadetakenundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))
        await model.renamePerson(ada.id, to: "Ada Lovelace")
        await model.addPerson(named: "Ada")

        undo.undo()
        await model.personRenameTask?.value
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.people.map(\.name).sorted() == ["Ada", "Ada Lovelace"])
        #expect(model.transcript?.segments.first?.speaker == "Ada Lovelace")
        try await assertNoDanglingAssignments(model)
    }

    @Test("redoing a rename does nothing once the new name belongs to another person")
    func redoIntoATakenNameChangesNothing() async throws {
        let (model, _, _) = try await makeTwoAssignedEntries("cascadetakenredo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))
        await model.renamePerson(ada.id, to: "Ada Lovelace")
        undo.undo()
        await model.personRenameTask?.value
        await model.addPerson(named: "Ada Lovelace")

        undo.redo()
        await model.personRenameTask?.value
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.people.map(\.name).sorted() == ["Ada", "Ada Lovelace"])
        #expect(model.transcript?.segments.first?.speaker == "Ada")
        try await assertNoDanglingAssignments(model)
    }

    @Test("an entry opened while the rename is still reaching it comes back under its own label")
    func entryOpenedMidCascadeIsRestored() async throws {
        let (model, open, other) = try await makeTwoAssignedEntries("cascademid")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))
        let gate = CascadeGate()
        model.personRenameCascadeHook = { while !gate.open { try? await Task.sleep(for: .milliseconds(5)) } }

        let renaming = Task { await model.renamePerson(ada.id, to: "Ada Lovelace") }
        #expect(await waitUntil { model.transcript?.segments.first?.speaker == "Ada Lovelace" })
        undo.undo()
        _ = try await model.openEntry(other.id)
        gate.open = true
        await renaming.value
        await model.personRenameTask?.value
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.people.map(\.name) == ["Ada"])
        #expect(model.transcript?.segments.map(\.speaker) == ["Ada", "SPEAKER_01", "Ada"])
        #expect(try await storedSpeakers(model, other.id) == ["Ada", "SPEAKER_01", "Ada"])
        #expect(try await storedSpeakers(model, open.id) == ["Ada", "SPEAKER_01", "Ada"])
        try await assertNoDanglingAssignments(model)
    }

    @Test("a merge registers no undo, as its alert says")
    func mergeRegistersNoUndo() async throws {
        let (model, _, _) = try await makeTwoAssignedEntries("cascademergeundo", secondPerson: "Grace")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))
        let grace = try #require(model.people.first { $0.name == "Grace" })

        await model.mergePerson(ada.id, into: grace.id)

        #expect(model.transcript?.segments.first?.speaker == "Grace")
        #expect(!undo.canUndo)
    }

    @Test("merging rewrites the source's name and drops the source person")
    func mergeCascades() async throws {
        let (model, open, other) = try await makeTwoAssignedEntries("cascademerge", secondPerson: "Grace")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        let grace = try #require(model.people.first { $0.name == "Grace" })

        await model.mergePerson(grace.id, into: ada.id)

        #expect(model.people.map(\.name) == ["Ada"])
        #expect(model.people.first?.usageCount == 2)
        #expect(model.libraryEntry(id: other.id)?.speakerAssignments == ["Ada": ada.id])
        #expect(model.libraryEntry(id: open.id)?.speakerAssignments == ["Ada": ada.id])
        #expect(try await storedSpeakers(model, other.id) == ["Ada", "SPEAKER_01", "Ada"])
    }

    @Test("deleting a person clears the maps and leaves the names in the transcripts")
    func deleteClearsTheMaps() async throws {
        let (model, open, other) = try await makeTwoAssignedEntries("cascadedelete")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.deletePerson(ada.id)

        #expect(model.people.isEmpty)
        #expect(model.libraryEntry(id: other.id)?.speakerAssignments.isEmpty == true)
        #expect(model.libraryEntry(id: open.id)?.speakerAssignments.isEmpty == true)
        #expect(model.transcript?.segments.first?.speaker == "Ada")
        #expect(try await storedSpeakers(model, other.id) == ["Ada", "SPEAKER_01", "Ada"])
    }

    @Test("deleting the filtered person clears the filter")
    func deleteClearsTheFilter() async throws {
        let (model, _, _) = try await makeTwoAssignedEntries("cascadefilter")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        model.browsePerson(ada.id)

        await model.deletePerson(ada.id)

        #expect(model.people.isEmpty)
        #expect(model.personFilter == nil)
    }

    @Test("renaming into a name already taken folds the two together")
    func renameIntoAnExistingName() async throws {
        let (model, _, other) = try await makeTwoAssignedEntries("cascadefold", secondPerson: "Grace")
        let grace = try #require(model.people.first { $0.name == "Grace" })

        await model.renamePerson(grace.id, to: "Ada")

        #expect(model.people.map(\.name) == ["Ada"])
        #expect(try await storedSpeakers(model, other.id) == ["Ada", "SPEAKER_01", "Ada"])
    }
}
