import Foundation
import Testing
@testable import ParolaCore

private actor RecordingIndexer: LibraryIndexer {
    private(set) var indexed: [String] = []
    private(set) var deindexed: [String] = []

    func index(id: String, title: String, text: String, createdAt: Date) async {
        indexed.append(id)
    }

    func deindex(id: String) async {
        deindexed.append(id)
    }
}

@Suite("LibraryStore Spotlight lifecycle", .tags(.fileSystem))
struct LibraryStoreSpotlightTests {
    private func makeStore(indexer: RecordingIndexer) throws -> LibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-spotlight-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: tmp, extraIndexer: indexer)
    }

    private func addEntry(to store: LibraryStore) async throws -> LibraryEntry {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-spotlight-audio-\(UUID().uuidString).wav")
        try Data("RIFFfakeaudio".utf8).write(to: audio)
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "private meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        return try await store.add(transcript: transcript, audioSource: audio)
    }

    @Test("soft-deleting an entry removes it from the extra indexer")
    func softDeleteDeindexes() async throws {
        let indexer = RecordingIndexer()
        let store = try makeStore(indexer: indexer)
        let entry = try await addEntry(to: store)
        await store.waitForExtraIndexer()
        #expect(await indexer.indexed == [entry.id])

        try await store.delete(entry.id)
        await store.waitForExtraIndexer()
        #expect(
            await indexer.deindexed == [entry.id],
            "a trashed transcript must leave Spotlight immediately, not after the 30-day purge"
        )
    }

    @Test("a late write into a trashed entry keeps it out of Spotlight")
    func writeToTrashedEntryStaysOut() async throws {
        let indexer = RecordingIndexer()
        let store = try makeStore(indexer: indexer)
        let entry = try await addEntry(to: store)
        try await store.delete(entry.id)

        try await store.mutateTranscript(for: entry.id) { $0.summary = Summary(text: "late recap") }
        try await store.setSummary(Summary(text: "late recap"), for: entry.id)
        await store.waitForExtraIndexer()

        #expect(await indexer.indexed == [entry.id], "only the add indexed it")
        #expect(try await store.load(entry.id).document.transcript.summary?.text == "late recap")
    }

    @Test("restoring a soft-deleted entry re-indexes it")
    func restoreReindexes() async throws {
        let indexer = RecordingIndexer()
        let store = try makeStore(indexer: indexer)
        let entry = try await addEntry(to: store)
        try await store.delete(entry.id)

        try await store.restore(entry.id)
        await store.waitForExtraIndexer()
        #expect(
            await indexer.indexed == [entry.id, entry.id],
            "a restored entry must be searchable again"
        )
        let matches = await store.search("private meeting")
        #expect(matches.map(\.entryID) == [entry.id], "in-app search must find the restored entry")
    }
}
