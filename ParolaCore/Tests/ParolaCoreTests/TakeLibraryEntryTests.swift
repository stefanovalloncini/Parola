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
