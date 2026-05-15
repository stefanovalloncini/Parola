import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("LibraryStore")
struct LibraryStoreTests {
    private func makeTempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp), tmp)
    }

    private var sampleAudioURL: URL {
        Bundle(for: BundleAnchor.self).url(forResource: "sample", withExtension: "wav")!
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "hi")],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("empty library lists nothing")
    func emptyList() async throws {
        let (store, _) = try makeTempLibrary()
        let entries = await store.list()
        #expect(entries.isEmpty)
    }

    @Test("add writes a .parola bundle and list returns it")
    func addAndList() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        #expect(entry.bundleURL.pathExtension == "parola")
        #expect(FileManager.default.fileExists(atPath: entry.bundleURL.path))

        let entries = await store.list()
        #expect(entries.count == 1)
        #expect(entries.first?.id == entry.id)
    }

    @Test("load round-trips transcript and audio URL")
    func loadRoundTrip() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        let loaded = try await store.load(entry.id)
        #expect(loaded.document.transcript.segments.first?.text == "hi")
        #expect(loaded.document.audioURL?.lastPathComponent.hasPrefix("audio.") == true)
    }

    @Test("add with nil audio source stores a transcript-only bundle")
    func addWithoutAudio() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let loaded = try await store.load(entry.id)
        #expect(loaded.document.audioURL == nil)
        #expect(loaded.document.transcript.segments.first?.text == "hi")
    }

    @Test("delete invalidates the loaded cache")
    func deleteInvalidatesCache() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        _ = try await store.load(entry.id)
        try await store.delete(entry.id)
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.load(entry.id)
        }
    }

    @Test("loading missing entry throws notFound")
    func loadMissingThrows() async throws {
        let (store, _) = try makeTempLibrary()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.load("does-not-exist")
        }
    }

    @Test("delete removes the directory")
    func deleteEntry() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        try await store.delete(entry.id)
        let exists = FileManager.default.fileExists(atPath: entry.bundleURL.path)
        #expect(exists == false)
        let entries = await store.list()
        #expect(entries.isEmpty)
    }

    @Test("deleting a missing entry throws notFound")
    func deleteMissingThrows() async throws {
        let (store, _) = try makeTempLibrary()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.delete("nope")
        }
    }

    @Test("adopt imports an existing .parola bundle without re-transcribing")
    func adoptParolaBundle() async throws {
        let (store, tmp) = try makeTempLibrary()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-\(UUID().uuidString).parola", isDirectory: true)
        try ParolaDocument.write(
            transcript: makeTranscript(),
            audioURL: sampleAudioURL,
            to: scratch
        )
        let entry = try await store.adopt(parolaBundle: scratch)
        #expect(entry.bundleURL.deletingLastPathComponent() == tmp)
        #expect(entry.bundleURL.pathExtension == "parola")
        let entries = await store.list()
        #expect(entries.count == 1)
    }
}

private final class BundleAnchor {}
