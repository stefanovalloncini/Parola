import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Seeds a library entry with two speakers, opens it, and waits for the model to settle on it.
@MainActor
enum PeopleTestSupport {
    static func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    static func transcript(text: String = "hello") -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(
                    id: 0, start: 0, end: 1, text: text, speaker: "SPEAKER_00",
                    words: [WordTiming(id: "0-0", word: text, start: 0, end: 1, probability: 1, speaker: "SPEAKER_00")]
                ),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "there", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "again", speaker: "SPEAKER_00"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    static func seed(_ model: AppModel, text: String = "hello") async throws -> LibraryEntry {
        // A no-Spotlight store on the model's library dir: the real indexer can hang in the test host.
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await store.add(transcript: transcript(text: text), audioSource: nil, category: .transcription)
        await model.refreshLibraryAndWait()
        return entry
    }

    static func open(_ model: AppModel, entry: LibraryEntry) async throws {
        model.loadEntry(entry.id)
        try await until { model.selectedEntryID == entry.id && model.transcript != nil }
        // loadEntry ends with a library refresh; letting it land keeps its snapshot from
        // overwriting the map a later assignment patches in.
        await model.libraryRefreshTask?.value
    }

    static func openSeededEntry(_ model: AppModel) async throws -> LibraryEntry {
        let entry = try await seed(model)
        try await open(model, entry: entry)
        return entry
    }

    /// Polls a condition on the main actor. Fails the test rather than hanging when it never holds.
    static func until(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition never held", sourceLocation: sourceLocation)
    }
}

@MainActor
@Suite("Assigning speakers to people")
struct AssignSpeakerPeopleTests {

    @Test("assigning a new name renames every segment with that label and records the map")
    func assignNewPerson() async throws {
        let model = PeopleTestSupport.makeModel("assignpeople")
        let entry = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")

        #expect(model.transcript?.segments.map(\.speaker) == ["Ada", "SPEAKER_01", "Ada"])
        #expect(model.transcript?.segments.first?.words?.map(\.speaker) == ["Ada"])
        let person = try #require(model.person(forSpeaker: "Ada"))
        #expect(person.usageCount == 1)
        #expect(model.speakerAssignments == ["Ada": person.id])
        #expect(model.libraryEntry(id: entry.id)?.personIDs == [person.id])
    }

    @Test("the map reaches the bundle on disk")
    func mapIsPersisted() async throws {
        let model = PeopleTestSupport.makeModel("assignpersist")
        let entry = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let assigned = try #require(model.speakerAssignments["Ada"])

        let stored = try await model.library.load(entry.id).entry.speakerAssignments
        #expect(stored == ["Ada": assigned])
    }

    @Test("assigning an existing person counts the use and re-keys the map")
    func assignExistingPerson() async throws {
        let model = PeopleTestSupport.makeModel("assignexisting")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.assignSpeaker(label: "SPEAKER_01", to: ada)

        #expect(model.people.first?.usageCount == 2)
        #expect(model.transcript?.segments.map(\.speaker) == ["Ada", "Ada", "Ada"])
        #expect(model.speakerAssignments == ["Ada": ada.id])
    }

    @Test("the assignment is one undo step, and undo puts the labels back")
    func assignmentUndoes() async throws {
        let model = PeopleTestSupport.makeModel("assignundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        #expect(undo.undoActionName == "Assign Speaker")

        undo.undo()
        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
    }

    @Test("clearing a speaker drops the label from the segments and the map")
    func clearSpeaker() async throws {
        let model = PeopleTestSupport.makeModel("assignclear")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")

        await model.clearSpeaker(label: "Ada")

        #expect(model.transcript?.segments.map(\.speaker) == [nil, "SPEAKER_01", nil])
        #expect(model.transcript?.segments.first?.words?.map(\.speaker) == [nil])
        #expect(model.speakerAssignments.isEmpty)
    }

    @Test("a per-segment assign still touches one segment, and records the person it named")
    func perSegmentAssignRecordsTheMap() async throws {
        let model = PeopleTestSupport.makeModel("assignsegment")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        model.assignSpeaker("Grace", toSegmentID: 1)
        try await PeopleTestSupport.until { model.speakerAssignments["Grace"] != nil }

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "Grace", "SPEAKER_00"])
        let grace = try #require(model.person(forSpeaker: "Grace"))
        #expect(grace.name == "Grace")
        #expect(model.people.map(\.name) == ["Grace"])
    }

    @Test("an assignment outside the library rewrites the transcript and records nothing")
    func assignWithoutAnEntry() async throws {
        let model = PeopleTestSupport.makeModel("assignnoentry")
        model.transcript = PeopleTestSupport.transcript()

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")

        #expect(model.transcript?.segments.first?.speaker == "Ada")
        #expect(model.speakerAssignments.isEmpty)
        #expect(model.people.map(\.name) == ["Ada"])
    }

    @Test("an assigned label wears the person's colour, an unassigned one its own")
    func chipColours() async throws {
        let model = PeopleTestSupport.makeModel("assigncolour")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        #expect(DS.speakerColor(for: "Ada", colorIndex: ada.colorIndex) == DS.speakerPalette[ada.colorIndex])
        #expect(DS.speakerColor(for: "SPEAKER_01", colorIndex: nil) == DS.speakerColor(for: "SPEAKER_01"))
    }

    @Test("the palette has a colour for every index the store hands out")
    func paletteCoversTheStore() {
        #expect(DS.speakerPalette.count == PeopleStore.colorCount)
    }

    @Test("the inspector counts the segments behind each speaker")
    func speakerSegmentCounts() async throws {
        let model = PeopleTestSupport.makeModel("assigncounts")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        let rows = model.speakerSegmentCounts
        #expect(rows.map(\.label) == ["SPEAKER_00", "SPEAKER_01"])
        #expect(rows.map(\.count) == [2, 1])
    }
}
