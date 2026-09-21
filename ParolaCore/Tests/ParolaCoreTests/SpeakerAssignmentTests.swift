import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Speaker assignments in the manifest", .tags(.fileSystem))
struct SpeakerAssignmentTests {

    private let ada = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let grace = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!

    private func makeStore() throws -> LibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-speaker-assignment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: tmp, extraIndexer: nil)
    }

    private func addEntry(to store: LibraryStore, text: String = "ciao") async throws -> LibraryEntry {
        try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text, speaker: "Ada")],
                language: "it",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
    }

    @Test("a manifest written before assignments existed decodes with none")
    func legacyDecode() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.mp3",
         "modelName": "m", "language": "en", "category": "transcription", "source": "file"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.speakerAssignments.isEmpty)
    }

    @Test("an empty map stays out of the written manifest and a filled one round-trips")
    func emptyMapIsOmitted() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.mp3", modelName: "m", language: "it")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(!String(decoding: try encoder.encode(manifest), as: UTF8.self).contains("speakerAssignments"))

        manifest.speakerAssignments = ["Ada": ada, "Grace": grace]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.speakerAssignments == manifest.speakerAssignments)
    }

    @Test("setSpeakerAssignments lands on the entry and replaces the whole map")
    func storeWriteReplacesTheMap() async throws {
        let store = try makeStore()
        let entry = try await addEntry(to: store)

        try await store.setSpeakerAssignments(["Ada": ada, "Grace": grace], for: entry.id)
        var reloaded = try await store.load(entry.id)
        #expect(reloaded.entry.speakerAssignments == ["Ada": ada, "Grace": grace])

        try await store.setSpeakerAssignments(["Ada": ada], for: entry.id)
        reloaded = try await store.load(entry.id)
        #expect(reloaded.entry.speakerAssignments == ["Ada": ada])
    }

    @Test("the cached entry list carries the written map")
    func cachedListCarriesTheMap() async throws {
        let store = try makeStore()
        let entry = try await addEntry(to: store)

        try await store.setSpeakerAssignments(["Ada": ada], for: entry.id)

        let listed = await store.list().first { $0.id == entry.id }
        #expect(listed?.speakerAssignments == ["Ada": ada])
    }

    @Test("personIDs are the map's values, without duplicates")
    func personIDsAreTheValues() async throws {
        let store = try makeStore()
        let entry = try await addEntry(to: store)

        try await store.setSpeakerAssignments(["Ada": ada, "A. Lovelace": ada, "Grace": grace], for: entry.id)

        let reloaded = try await store.load(entry.id)
        #expect(reloaded.entry.personIDs == [ada, grace])
    }

    @Test("an entry with no assignments has no person ids")
    func noAssignmentsNoPeople() async throws {
        let store = try makeStore()
        let entry = try await addEntry(to: store)
        #expect(entry.personIDs.isEmpty)
    }

    @Test("assigning on an entry that isn't there reports it")
    func missingEntry() async throws {
        let store = try makeStore()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.setSpeakerAssignments(["Ada": ada], for: "nope")
        }
    }
}
