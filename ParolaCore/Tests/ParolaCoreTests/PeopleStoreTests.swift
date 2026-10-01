import Foundation
import Testing
@testable import ParolaCore

@Suite("People registry")
struct PeopleStoreTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-people-tests-\(UUID().uuidString).json")
    }

    @Test("recording a new name creates a Person")
    func newName() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        _ = await store.recordUsage(name: "Stefano")
        let people = await store.people
        #expect(people.count == 1)
        #expect(people.first?.name == "Stefano")
        #expect(people.first?.usageCount == 1)
    }

    @Test("recording the same name twice bumps usageCount")
    func repeatedName() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        _ = await store.recordUsage(name: "Stefano")
        _ = await store.recordUsage(name: "Stefano")
        let people = await store.people
        #expect(people.count == 1)
        #expect(people.first?.usageCount == 2)
    }

    @Test("name matching is case-insensitive but the canonical form follows the latest input")
    func caseInsensitive() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        _ = await store.recordUsage(name: "stefano")
        _ = await store.recordUsage(name: "Stefano")
        let people = await store.people
        #expect(people.count == 1)
        #expect(people.first?.name == "Stefano")
    }

    @Test("suggestions are sorted by recent usage and limited")
    func suggestions() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await store.recordUsage(name: "Alice", at: base)
        _ = await store.recordUsage(name: "Bob", at: base.addingTimeInterval(60))
        _ = await store.recordUsage(name: "Cara", at: base.addingTimeInterval(120))
        let suggestions = await store.suggestions(limit: 2)
        #expect(suggestions.map(\.name) == ["Cara", "Bob"])
    }

    @Test("delete drops the person and persists")
    func delete() async throws {
        let url = makeTempURL()
        let store = PeopleStore(storageURL: url)
        let p = await store.recordUsage(name: "Stefano")
        let ok = await store.delete(p.id)
        #expect(ok)
        let reopened = PeopleStore(storageURL: url)
        let people = await reopened.people
        #expect(people.isEmpty)
    }

    @Test("a directory written before colours existed is spread over the palette once")
    func legacyColoursSpread() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let names = ["Alice", "Bob", "Cara", "Dan"]
        let legacy = names.map { name in
            """
            {"id":"\(UUID().uuidString)","name":"\(name)","lastUsedAt":747000000,"usageCount":1}
            """
        }
        try Data("[\(legacy.joined(separator: ","))]".utf8).write(to: url)

        let store = PeopleStore(storageURL: url)
        let spread = await store.people
        #expect(spread.map(\.colorIndex) == [0, 1, 2, 3])

        // Written back, so the next launch reads the same colours instead of spreading again.
        let reopened = PeopleStore(storageURL: url)
        #expect(await reopened.people.map(\.colorIndex) == [0, 1, 2, 3])
    }

    @Test("a colour someone already holds survives the spread")
    func chosenColoursSurviveTheSpread() {
        var people = [
            Person(name: "Alice", colorIndex: 0),
            Person(name: "Bob", colorIndex: 2),
            Person(name: "Cara", colorIndex: 0),
        ]
        #expect(PeopleStore.spreadDefaultColours(&people))
        #expect(people.map(\.colorIndex) == [0, 2, 1])
        #expect(!PeopleStore.spreadDefaultColours(&people), "the spread is one-shot")
    }

    @Test("registry persists across instances")
    func persistence() async throws {
        let url = makeTempURL()
        let store1 = PeopleStore(storageURL: url)
        _ = await store1.recordUsage(name: "Stefano")
        let store2 = PeopleStore(storageURL: url)
        let people = await store2.people
        #expect(people.first?.name == "Stefano")
    }

    @Test("Transcript.uniqueSpeakers returns first-seen order")
    func uniqueSpeakers() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "hi", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "there", speaker: "SPEAKER_02"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "ok", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 3, start: 3, end: 4, text: "no speaker"),
            ],
            language: "en",
            modelName: "tiny"
        )
        #expect(transcript.uniqueSpeakers == ["SPEAKER_01", "SPEAKER_02"])
    }

    @Test("uniqueSpeakers treats an empty-string speaker as no speaker")
    func uniqueSpeakersSkipsEmpty() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "hi", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "blank", speaker: ""),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "no speaker"),
            ],
            language: "en",
            modelName: "tiny"
        )
        #expect(transcript.uniqueSpeakers == ["SPEAKER_01"])
    }

    @Test("Transcript.renamingSpeaker rewrites every matching segment")
    func renamingSpeaker() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "hi", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "there", speaker: "SPEAKER_02"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "ok", speaker: "SPEAKER_01"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let renamed = transcript.renamingSpeaker("SPEAKER_01", to: "Stefano")
        #expect(renamed.segments.map(\.speaker) == ["Stefano", "SPEAKER_02", "Stefano"])
    }

    @Test("renamingSpeaker also rewrites word-level speaker labels")
    func renamingSpeakerRewritesWords() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(
                    id: 0, start: 0, end: 2, text: "hi there", speaker: "SPEAKER_01",
                    words: [
                        WordTiming(id: "0-0", word: "hi", start: 0, end: 1, probability: 1, speaker: "SPEAKER_01"),
                        WordTiming(id: "0-1", word: "there", start: 1, end: 2, probability: 1, speaker: "SPEAKER_01"),
                    ]
                ),
                TranscriptSegment(
                    id: 1, start: 2, end: 3, text: "ok", speaker: "SPEAKER_02",
                    words: [
                        WordTiming(id: "1-0", word: "ok", start: 2, end: 3, probability: 1, speaker: "SPEAKER_02"),
                    ]
                ),
            ],
            language: "en",
            modelName: "tiny"
        )
        let renamed = transcript.renamingSpeaker("SPEAKER_01", to: "Stefano")
        #expect(renamed.segments[0].words?.map(\.speaker) == ["Stefano", "Stefano"])
        #expect(renamed.segments[1].words?.map(\.speaker) == ["SPEAKER_02"])
    }

    @Test("renamingSpeaker ignores empty target")
    func renamingEmpty() {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi", speaker: "SPEAKER_01")],
            language: "en",
            modelName: "tiny"
        )
        let renamed = transcript.renamingSpeaker("SPEAKER_01", to: "  ")
        #expect(renamed.segments.first?.speaker == "SPEAKER_01")
    }

    @Test("rename preserves usage count and lastUsedAt")
    func renamePreservesHistory() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await store.recordUsage(name: "Stefano", at: base)
        _ = await store.recordUsage(name: "Stefano", at: base.addingTimeInterval(60))
        let original = try #require(await store.people.first)
        let renamed = try #require(await store.rename(original.id, to: "Steve"))
        #expect(renamed.name == "Steve")
        #expect(renamed.usageCount == 2)
        #expect(renamed.lastUsedAt == base.addingTimeInterval(60))
    }

    @Test("rename to empty string is a no-op")
    func renameEmptyNoop() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let p = await store.recordUsage(name: "Stefano")
        let result = await store.rename(p.id, to: "  ")
        #expect(result == nil)
        let people = await store.people
        #expect(people.first?.name == "Stefano")
    }

    @Test("rename merges into an existing person when the target name matches")
    func renameMergesDuplicate() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let a = await store.recordUsage(name: "SPEAKER_01")
        _ = await store.recordUsage(name: "Stefano")
        _ = await store.recordUsage(name: "Stefano")
        _ = await store.rename(a.id, to: "Stefano")
        let people = await store.people
        #expect(people.count == 1)
        #expect(people.first?.name == "Stefano")
        #expect(people.first?.usageCount == 3)
    }

    @Test("recordUsage ignores an empty or whitespace-only name")
    func recordUsageEmptyNoop() async {
        let store = PeopleStore(storageURL: makeTempURL())
        _ = await store.recordUsage(name: "  ")
        _ = await store.recordUsage(name: "")
        let people = await store.people
        #expect(people.isEmpty)
    }

    @Test("recordUsage folds composed-vs-decomposed unicode")
    func diacriticNormalization() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let composed = "Jos\u{00e9}"        // é precomposed
        let decomposed = "Jose\u{0301}"      // é decomposed
        _ = await store.recordUsage(name: composed)
        _ = await store.recordUsage(name: decomposed)
        let people = await store.people
        #expect(people.count == 1)
        #expect(people.first?.usageCount == 2)
    }

    @Test("merge sums usage, keeps the newest date, and drops the source")
    func mergeSumsUsage() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let source = await store.recordUsage(name: "SPEAKER_01", at: base.addingTimeInterval(600))
        _ = await store.recordUsage(name: "Stefano", at: base)
        let target = await store.recordUsage(name: "Stefano", at: base)

        let merged = try #require(await store.merge(source.id, into: target.id))

        #expect(merged.name == "Stefano")
        #expect(merged.usageCount == 3)
        #expect(merged.lastUsedAt == base.addingTimeInterval(600))
        let people = await store.people
        #expect(people.map(\.id) == [target.id])
    }

    @Test("merging a person into itself changes nothing")
    func mergeIntoSelf() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let person = await store.recordUsage(name: "Stefano")

        #expect(await store.merge(person.id, into: person.id) == nil)
        #expect(await store.people.count == 1)
        #expect(await store.people.first?.usageCount == 1)
    }

    @Test("merging an unknown id changes nothing")
    func mergeUnknown() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let person = await store.recordUsage(name: "Stefano")

        #expect(await store.merge(UUID(), into: person.id) == nil)
        #expect(await store.merge(person.id, into: UUID()) == nil)
        #expect(await store.people.count == 1)
    }

    @Test("delete drops the person and persists")
    func deletePersists() async throws {
        let url = makeTempURL()
        let store = PeopleStore(storageURL: url)
        let person = await store.recordUsage(name: "Stefano")

        #expect(await store.delete(person.id))
        #expect(await PeopleStore(storageURL: url).people.isEmpty)
    }

    @Test("mostUsed sorts by usage, then by the newest use")
    func mostUsedOrder() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await store.recordUsage(name: "Alice", at: base)
        _ = await store.recordUsage(name: "Alice", at: base)
        _ = await store.recordUsage(name: "Bob", at: base.addingTimeInterval(60))
        _ = await store.recordUsage(name: "Cara", at: base.addingTimeInterval(120))

        #expect(await store.mostUsed(limit: 2).map(\.name) == ["Alice", "Cara"])
        #expect(await store.mostUsed(limit: 10).map(\.name) == ["Alice", "Cara", "Bob"])
    }

    @Test("person(named:) matches the way recordUsage does")
    func lookupByName() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let person = await store.recordUsage(name: "Stefano")

        #expect(await store.person(named: " stefano ")?.id == person.id)
        #expect(await store.person(named: "Nobody") == nil)
    }

    @Test("each new person takes the next free colour, and it survives a reopen")
    func colourIndicesAreStableAndPersisted() async throws {
        let url = makeTempURL()
        let store = PeopleStore(storageURL: url)
        for name in ["A", "B", "C"] { _ = await store.recordUsage(name: name) }

        #expect(await store.people.map(\.colorIndex) == [0, 1, 2])

        _ = await store.delete(try #require(await store.person(named: "B")).id)
        let filling = await store.recordUsage(name: "D")
        #expect(filling.colorIndex == 1)

        let reopened = PeopleStore(storageURL: url)
        #expect(await reopened.people.map(\.colorIndex).sorted() == [0, 1, 2])
    }

    @Test("colours wrap once every index is taken")
    func colourIndicesWrap() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        for index in 0..<(PeopleStore.colorCount + 1) {
            _ = await store.recordUsage(name: "P\(index)")
        }
        let people = await store.people
        #expect(people.count == PeopleStore.colorCount + 1)
        #expect(people.last?.colorIndex == 0)
        #expect(people.allSatisfy { (0..<PeopleStore.colorCount).contains($0.colorIndex) })
    }

    @Test("a person stored before colours decodes with the first one")
    func legacyPersonDecode() throws {
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","name":"Ada",
          "lastUsedAt":770000000,"usageCount":3}]
        """
        let people = try JSONDecoder().decode([Person].self, from: Data(json.utf8))
        #expect(people.first?.colorIndex == 0)
        #expect(people.first?.usageCount == 3)
        #expect(people.first?.isMe == false)
    }

    @Test("marking someone as you clears everyone else, survives a reopen, and nil clears it")
    func markAsMe() async throws {
        let url = makeTempURL()
        let store = PeopleStore(storageURL: url)
        let ada = await store.recordUsage(name: "Ada")
        let grace = await store.recordUsage(name: "Grace")

        await store.markAsMe(ada.id)
        await store.markAsMe(grace.id)
        let marked = await store.people.filter(\.isMe).map(\.id)
        #expect(marked == [grace.id])
        #expect(await PeopleStore(storageURL: url).me?.id == grace.id)

        await store.markAsMe(UUID())
        #expect(await store.me?.id == grace.id)

        await store.markAsMe(nil)
        #expect(await store.me == nil)
        #expect(await PeopleStore(storageURL: url).me == nil)
    }

    @Test("the me mark moves with a merge and with a rename onto someone else, and goes with a delete")
    func meMarkFollowsThePerson() async throws {
        let store = PeopleStore(storageURL: makeTempURL())
        let alias = await store.recordUsage(name: "SPEAKER_01")
        let stefano = await store.recordUsage(name: "Stefano")
        await store.markAsMe(alias.id)

        _ = await store.merge(alias.id, into: stefano.id)
        #expect(await store.me?.id == stefano.id)

        let steve = await store.recordUsage(name: "Steve")
        _ = await store.rename(stefano.id, to: "Steve")
        #expect(await store.me?.id == steve.id)

        _ = await store.delete(steve.id)
        #expect(await store.me == nil)
    }
}
