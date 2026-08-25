import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Navigation persistence")
struct NavigationPersistenceTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            libraryURL: makeTempLibraryURL("navigation")
        )
    }

    private func seedEntry(in model: AppModel, text: String) async throws -> LibraryEntry {
        let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        return try await seed.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
    }

    private func waitUntil(timeoutMs: Int = 10_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    private func openEntry(_ id: LibraryEntry.ID, in model: AppModel) async -> Bool {
        model.loadEntry(id)
        return await waitUntil { model.selectedEntryID == id }
    }

    private func transcriptState(of entry: LibraryEntry) throws -> (bytes: Data, modified: Date?) {
        let url = entry.bundleURL.appendingPathComponent("transcript.json")
        let bytes = try Data(contentsOf: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (bytes, modified)
    }

    private func manifest(of entry: LibraryEntry) throws -> ParolaDocument.Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: entry.bundleURL.appendingPathComponent("manifest.json"))
        return try decoder.decode(ParolaDocument.Manifest.self, from: data)
    }

    @Test("browsing entries leaves their transcripts and updatedAt untouched")
    func browsingDoesNotRewriteBundles() async throws {
        let model = makeModel()
        let first = try await seedEntry(in: model, text: "first entry")
        let second = try await seedEntry(in: model, text: "second entry")
        let before = try transcriptState(of: first)

        #expect(await openEntry(first.id, in: model))
        #expect(await openEntry(second.id, in: model))
        #expect(await openEntry(first.id, in: model))
        #expect(await openEntry(second.id, in: model))

        let after = try transcriptState(of: first)
        #expect(after.bytes == before.bytes)
        #expect(after.modified == before.modified, "transcript.json was rewritten by plain navigation")
        #expect(try manifest(of: first).updatedAt == nil, "updatedAt moved without an edit")
        #expect(try manifest(of: second).updatedAt == nil, "updatedAt moved without an edit")
    }

    @Test("opening an entry records lastOpenedAt")
    func openingRecordsLastOpened() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "first entry")

        #expect(await openEntry(entry.id, in: model))
        let opened = await waitUntil { (try? manifest(of: entry).lastOpenedAt) ?? nil != nil }
        #expect(opened)
    }

    @Test("an edit still bumps updatedAt on the way out")
    func editStillPersists() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "first entry")
        let other = try await seedEntry(in: model, text: "second entry")

        #expect(await openEntry(entry.id, in: model))
        model.editSegment(id: 0, newText: "edited")
        #expect(await openEntry(other.id, in: model))

        let edited = try manifest(of: entry)
        #expect(edited.updatedAt != nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: entry.bundleURL.appendingPathComponent("transcript.json"))
        let transcript = try decoder.decode(Transcript.self, from: data)
        #expect(transcript.segments[0].text == "edited")
    }
}
