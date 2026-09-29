import Foundation
import Testing
@testable import ParolaCore

@Suite("A take's library entry", .tags(.fileSystem))
struct TakeLibraryEntryTests {
    private func makeLibrary() throws -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-take-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: url, extraIndexer: nil)
    }

    private func makeAudio(_ bytes: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-take-entry-\(UUID().uuidString).wav")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private let untranscribed = Transcript(segments: [], language: "auto", modelName: "")

    @Test("an entry made from the same bytes is found, even from Recently Deleted")
    func digestMatchesIncludeDeletedEntries() async throws {
        let store = try makeLibrary()
        let kept = try makeAudio("RIFFkept")
        let trashed = try makeAudio("RIFFtrashed")
        defer {
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: trashed)
        }
        _ = try await store.add(transcript: untranscribed, audioSource: kept)
        let gone = try await store.add(transcript: untranscribed, audioSource: trashed)
        try await store.delete(gone.id)

        let keptDigest = try #require(try SourceDigest.compute(contentsOf: kept))
        let trashedDigest = try #require(try SourceDigest.compute(contentsOf: trashed))
        #expect(await store.hasEntry(digest: keptDigest))
        #expect(await store.hasEntry(digest: trashedDigest))
        #expect(await store.findEntry(digest: trashedDigest) == nil, "a lookup for reuse still skips the trash")
        #expect(!(await store.hasEntry(digest: String(repeating: "0", count: 64))))
        #expect(!(await store.hasEntry(digest: "")))
    }

    @Test("a working file is a take by its prefix; dictation and preview scratch are not")
    func takePrefixesTellTakesFromScratch() {
        let folder = FileManager.default.temporaryDirectory
        for prefix in RecordingScratch.takePrefixes {
            #expect(RecordingScratch.isTake(folder.appendingPathComponent("\(prefix)-A1B2.wav")), "\(prefix)")
        }
        #expect(!RecordingScratch.isTake(folder.appendingPathComponent("\(RecordingScratch.dictationPrefix)-A1B2.wav")))
        #expect(!RecordingScratch.isTake(folder.appendingPathComponent("\(RecordingScratch.previewPrefix)-A1B2.wav")))
        #expect(!RecordingScratch.isTake(folder.appendingPathComponent("parola-mic-A1B2.json")))
        #expect(!RecordingScratch.isTake(folder.appendingPathComponent("parola-microphone.wav")), "a prefix counts only up to its dash")
    }

    @Test("a stored title can be replaced, and a missing entry says so")
    func storedTitleIsReplaced() async throws {
        let store = try makeLibrary()
        let audio = try makeAudio("RIFFtitle")
        defer { try? FileManager.default.removeItem(at: audio) }
        let entry = try await store.add(transcript: untranscribed, audioSource: audio, title: "Recording 1 (not transcribed)")

        try await store.replaceStoredTitle("Recording 1", for: entry.id)

        #expect(await store.list().first { $0.id == entry.id }?.title == "Recording 1")
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.replaceStoredTitle("Nope", for: "missing-entry")
        }
    }
}
