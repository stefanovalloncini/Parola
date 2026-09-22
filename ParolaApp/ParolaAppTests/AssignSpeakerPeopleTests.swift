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
        await waitUntil(timeoutMs: 3000) { model.selectedEntryID == entry.id && model.transcript != nil }
        // loadEntry ends with a library refresh; letting it land keeps its snapshot from
        // overwriting the map a later assignment patches in.
        await model.libraryRefreshTask?.value
    }

    static func openSeededEntry(_ model: AppModel) async throws -> LibraryEntry {
        let entry = try await seed(model)
        try await open(model, entry: entry)
        return entry
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

    @Test("renaming the label keeps the assignment, its colour and the filter")
    func renamingTheLabelKeepsTheAssignment() async throws {
        let model = PeopleTestSupport.makeModel("assignrenamelabel")
        let entry = try await PeopleTestSupport.openSeededEntry(model)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        model.renameSpeakerLabel("Ada", to: "Ada L.")
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.transcript?.segments.map(\.speaker) == ["Ada L.", "SPEAKER_01", "Ada L."])
        #expect(model.speakerAssignments == ["Ada L.": ada.id])
        #expect(model.person(forSpeaker: "Ada L.")?.id == ada.id)
        #expect(SpeakerPillState.of(person: model.person(forSpeaker: "Ada L."), label: "Ada L.") == .person("Ada"))
        #expect(model.speakerColorIndices["Ada L."] == ada.colorIndex)
        #expect(model.entries(withPerson: ada.id).map(\.id) == [entry.id])
        // The rename carried the person over instead of minting one under the new text.
        #expect(model.people.map(\.name) == ["Ada"])
        #expect(try await model.library.load(entry.id).entry.speakerAssignments == ["Ada L.": ada.id])
    }

    @Test("renaming a label nobody stands for to a fresh name mints nobody")
    func renamingAnUnassignedLabelMintsNobody() async throws {
        let model = PeopleTestSupport.makeModel("assignrenamefresh")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        model.renameSpeakerLabel("SPEAKER_01", to: "Grace")
        await model.awaitSpeakerAssignmentWrites()

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "Grace", "SPEAKER_00"])
        #expect(model.people.isEmpty)
        #expect(model.speakerAssignments.isEmpty)
    }

    @Test("renaming a label to someone the directory knows assigns them")
    func renamingAnUnassignedLabelToAKnownPersonAssigns() async throws {
        let model = PeopleTestSupport.makeModel("assignrenameknown")
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.addPerson(named: "Grace")
        let grace = try #require(model.person(named: "Grace"))

        model.renameSpeakerLabel("SPEAKER_01", to: "Grace")
        await waitUntil(timeoutMs: 3000) { model.people.first?.usageCount == 2 }

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "Grace", "SPEAKER_00"])
        #expect(model.speakerAssignments == ["Grace": grace.id])
        #expect(model.person(forSpeaker: "Grace")?.id == grace.id)
        #expect(model.speakerColorIndices["Grace"] == grace.colorIndex)
        #expect(model.people.map(\.name) == ["Grace"])
    }

    @Test("a name that only differs in case still lands on the same person")
    func renamingToADifferentSpellingAssignsTheSamePerson() async throws {
        let model = PeopleTestSupport.makeModel("assignrenamecase")
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.addPerson(named: "Grace Hopper")
        let grace = try #require(model.person(named: "Grace Hopper"))

        model.renameSpeakerLabel("SPEAKER_01", to: "grace hopper")
        await waitUntil(timeoutMs: 3000) { model.people.first?.usageCount == 2 }

        #expect(model.speakerAssignments == ["grace hopper": grace.id])
        // Counting the use must not rewrite the person to the typed spelling.
        #expect(model.people.map(\.name) == ["Grace Hopper"])
    }

    @Test("the Speakers sheet's renames come back on one undo")
    func bulkRenamesUndoTogether() async throws {
        let model = PeopleTestSupport.makeModel("assignbulkundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.addPerson(named: "Ada")
        await model.addPerson(named: "Grace")
        let ada = try #require(model.person(named: "Ada"))
        let grace = try #require(model.person(named: "Grace"))

        model.applySpeakerRenames(["SPEAKER_00": "Ada", "SPEAKER_01": "Grace"])
        await model.awaitSpeakerAssignmentWrites()
        #expect(model.transcript?.segments.map(\.speaker) == ["Ada", "Grace", "Ada"])
        #expect(model.speakerAssignments == ["Ada": ada.id, "Grace": grace.id])

        undo.undo()

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        #expect(model.speakerAssignments.isEmpty)
    }

    @Test("undo puts the map back, and redo re-applies it")
    func assignmentMapRoundTripsThroughUndo() async throws {
        let model = PeopleTestSupport.makeModel("assignmapundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))
        #expect(model.speakerAssignments == ["Ada": ada.id])

        undo.undo()
        #expect(model.transcript?.segments.first?.speaker == "SPEAKER_00")
        #expect(model.speakerAssignments.isEmpty)

        undo.redo()
        #expect(model.transcript?.segments.first?.speaker == "Ada")
        #expect(model.speakerAssignments == ["Ada": ada.id])
    }

    @Test("undo of a label rename re-keys the map back")
    func labelRenameMapRoundTripsThroughUndo() async throws {
        let model = PeopleTestSupport.makeModel("assignrenameundo")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        model.renameSpeakerLabel("Ada", to: "Ada L.")
        await model.awaitSpeakerAssignmentWrites()
        undo.undo()

        #expect(model.transcript?.segments.first?.speaker == "Ada")
        #expect(model.speakerAssignments == ["Ada": ada.id])
    }

    @Test("two assignments in flight both land in the map")
    func concurrentAssignmentsBothLand() async throws {
        let model = PeopleTestSupport.makeModel("assignconcurrent")
        let entry = try await PeopleTestSupport.openSeededEntry(model)

        async let first: Void = model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        async let second: Void = model.assignSpeaker(label: "SPEAKER_01", toNewPersonNamed: "Grace")
        _ = await (first, second)
        await model.awaitSpeakerAssignmentWrites()

        #expect(Set(model.speakerAssignments.keys) == ["Ada", "Grace"])
        let stored = try await model.library.load(entry.id).entry.speakerAssignments
        #expect(Set(stored.keys) == ["Ada", "Grace"])
    }

    @Test("re-picking the person already on a label counts no new use")
    func rePickingCountsNothing() async throws {
        let model = PeopleTestSupport.makeModel("assignrepick")
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.person(forSpeaker: "Ada"))

        await model.assignSpeaker(label: "Ada", to: ada)

        #expect(model.people.first?.usageCount == 1)
    }

    @Test("picking a raw label for one segment mints nobody")
    func perSegmentRawLabelMintsNobody() async throws {
        let model = PeopleTestSupport.makeModel("assignrawlabel")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        model.assignSpeaker("SPEAKER_01", toSegmentID: 0)
        // Let the store hop the per-segment path takes settle before reading the directory.
        await settle()

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_01", "SPEAKER_01", "SPEAKER_00"])
        #expect(model.people.isEmpty)
        #expect(model.speakerAssignments.isEmpty)
    }

    @Test("naming a segment's speaker makes the person and records the map")
    func perSegmentNewPersonMints() async throws {
        let model = PeopleTestSupport.makeModel("assignsegmentnew")
        _ = try await PeopleTestSupport.openSeededEntry(model)

        await model.assignSegment(1, toNewPersonNamed: "Grace")

        #expect(model.transcript?.segments.map(\.speaker) == ["SPEAKER_00", "Grace", "SPEAKER_00"])
        let grace = try #require(model.person(forSpeaker: "Grace"))
        #expect(grace.usageCount == 1)
        #expect(model.speakerAssignments == ["Grace": grace.id])
    }

    @Test("a per-segment pick of a name the directory knows records the map")
    func perSegmentKnownPersonRecordsTheMap() async throws {
        let model = PeopleTestSupport.makeModel("assignknownperson")
        _ = try await PeopleTestSupport.openSeededEntry(model)
        await model.addPerson(named: "Grace")

        model.assignSpeaker("Grace", toSegmentID: 1)
        await waitUntil(timeoutMs: 3000) { model.speakerAssignments["Grace"] != nil }

        let grace = try #require(model.person(forSpeaker: "Grace"))
        #expect(grace.usageCount == 2)
        #expect(model.people.map(\.name) == ["Grace"])
    }

    @Test("the pill names the person only when the label differs")
    func pillStates() {
        let ada = Person(name: "Ada")
        #expect(SpeakerPillState.of(person: nil, label: "SPEAKER_00") == .unassigned)
        #expect(SpeakerPillState.of(person: ada, label: "Ada") == .assigned)
        #expect(SpeakerPillState.of(person: ada, label: "SPEAKER_00") == .person("Ada"))
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
