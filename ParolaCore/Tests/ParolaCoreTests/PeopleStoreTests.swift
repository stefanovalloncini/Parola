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

    @Test("remove drops the person and persists")
    func remove() async throws {
        let url = makeTempURL()
        let store = PeopleStore(storageURL: url)
        let p = await store.recordUsage(name: "Stefano")
        let ok = await store.remove(p.id)
        #expect(ok)
        let reopened = PeopleStore(storageURL: url)
        let people = await reopened.people
        #expect(people.isEmpty)
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
}
