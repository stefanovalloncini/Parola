import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("LibraryStore", .serialized)
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
        #expect(loaded.document.audioURL.lastPathComponent.hasPrefix("audio."))
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

    @Test("list is sorted by createdAt descending")
    func sortedDescending() async throws {
        let (store, _) = try makeTempLibrary()
        let first = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let second = try await store.add(transcript: makeTranscript(), audioSource: sampleAudioURL)
        let entries = await store.list()
        #expect(entries.map(\.id) == [second.id, first.id])
    }

    @Test("adopt imports an existing .parola bundle without re-transcribing")
    func adoptParolaBundle() async throws {
        let (store, _) = try makeTempLibrary()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-\(UUID().uuidString).parola", isDirectory: true)
        try ParolaDocument.write(
            transcript: makeTranscript(),
            audioURL: sampleAudioURL,
            to: scratch
        )
        let entry = try await store.adopt(parolaBundle: scratch)
        #expect(entry.bundleURL.path.contains("Library") || entry.bundleURL.lastPathComponent.hasSuffix(".parola"))
        let entries = await store.list()
        #expect(entries.count == 1)
    }
}

private final class BundleAnchor {}
