import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

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

    @Test("only the open transcript's rewrite is undoable")
    func onlyTheOpenTranscriptUndoes() async throws {
        let (model, _, other) = try await makeTwoAssignedEntries("cascadeundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.renamePerson(ada.id, to: "Ada Lovelace")
        #expect(undo.undoActionName == "Rename Person")

        undo.undo()

        // The open transcript steps back to the name it carried; the other entry keeps the new one.
        #expect(model.transcript?.segments.first?.speaker == "Ada")
        #expect(try await storedSpeakers(model, other.id) == ["Ada Lovelace", "SPEAKER_01", "Ada Lovelace"])
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
        model.setPersonFilter(ada.id)

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
