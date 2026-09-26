import Foundation
import os
import Testing
@testable import Parola
import ParolaCore

@Suite("AppModel library")
@MainActor
struct AppModelLibraryTests {
    private func makeModel() throws -> (AppModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-appmodel-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (AppModel(libraryURL: tmp, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), tmp)
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
    }

    @Test("Open Last Transcript answers from the app's own store and asks RootView to open the entry")
    func openLatestUsesTheAppStore() async throws {
        defer { IntentPerformers.openLatest = nil }
        let (model, _) = try makeModel()
        let older = try await model.library.add(transcript: transcript("older words"), audioSource: nil)
        try ParolaDocument.updateManifest(at: older.bundleURL) { $0.createdAt = Date(timeIntervalSinceNow: -3600) }
        let newest = try await model.library.add(transcript: transcript("newest words"), audioSource: nil)
        let opened = OSAllocatedUnfairLock<String?>(initialState: nil)
        let observer = NotificationCenter.default.addObserver(forName: .parolaOpenEntry, object: nil, queue: nil) { note in
            let id = note.userInfo?["id"] as? String
            opened.withLock { $0 = id }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.registerIntentPerformers()

        let perform = try #require(IntentPerformers.openLatest)
        let text = try await perform()

        #expect(text == "newest words")
        #expect(opened.withLock { $0 } == newest.id)
    }

    @Test("an empty query clears the search results synchronously")
    func emptyQueryClears() throws {
        let (model, _) = try makeModel()
        model.searchResults = []
        model.search("")
        #expect(model.searchResults == nil)
    }

    @Test("a whitespace-only query is treated as empty")
    func whitespaceQueryClears() throws {
        let (model, _) = try makeModel()
        model.searchResults = []
        model.search("   ")
        #expect(model.searchResults == nil)
    }

    @Test("refreshLibrary publishes active and deleted entries")
    func refreshPublishesEntries() async throws {
        let (model, _) = try makeModel()
        let kept = try await model.library.add(transcript: transcript("kept"), audioSource: nil)
        let trashed = try await model.library.add(transcript: transcript("trashed"), audioSource: nil)
        try await model.library.delete(trashed.id)

        model.refreshLibrary()

        try await pollUntil {
            model.libraryEntries.map(\.id) == [kept.id]
                && model.deletedEntries.map(\.id) == [trashed.id]
        }
        #expect(model.libraryEntries.map(\.id) == [kept.id])
        #expect(model.deletedEntries.map(\.id) == [trashed.id])
    }

    @Test("search ranks matching entries and ignores non-matching ones")
    func searchFindsMatches() async throws {
        let (model, _) = try makeModel()
        let hit = try await model.library.add(
            transcript: transcript("the quick brown fox jumps"),
            audioSource: nil
        )
        _ = try await model.library.add(transcript: transcript("unrelated content here"), audioSource: nil)

        model.search("quick")

        try await pollUntil { model.searchResults != nil }
        let results = try #require(model.searchResults)
        #expect(results.map(\.id) == [hit.id])
    }

    @Test("deleteEntry moves an entry from the active list into the deleted list")
    func deleteMovesToTrash() async throws {
        let (model, _) = try makeModel()
        let kept = try await model.library.add(transcript: transcript("kept"), audioSource: nil)
        let target = try await model.library.add(transcript: transcript("doomed"), audioSource: nil)

        model.deleteEntry(target.id)

        try await pollUntil {
            model.libraryEntries.map(\.id) == [kept.id]
                && model.deletedEntries.map(\.id) == [target.id]
        }
        #expect(model.libraryEntries.map(\.id) == [kept.id])
        #expect(model.deletedEntries.map(\.id) == [target.id])
    }

    @Test("restoreEntry returns a soft-deleted entry to the active list")
    func restoreReturnsToActive() async throws {
        let (model, _) = try makeModel()
        let target = try await model.library.add(transcript: transcript("comeback"), audioSource: nil)
        try await model.library.delete(target.id)

        model.restoreEntry(target.id)

        try await pollUntil {
            model.libraryEntries.map(\.id) == [target.id]
                && model.deletedEntries.isEmpty
        }
        #expect(model.libraryEntries.map(\.id) == [target.id])
        #expect(model.deletedEntries.isEmpty)
    }

    @Test("purgeEntry permanently removes a soft-deleted entry")
    func purgeRemovesPermanently() async throws {
        let (model, _) = try makeModel()
        let target = try await model.library.add(transcript: transcript("gone"), audioSource: nil)
        model.deleteEntry(target.id)
        try await pollUntil { model.deletedEntries.map(\.id) == [target.id] }

        model.purgeEntry(target.id)
        try await pollUntil { model.libraryEntries.isEmpty && model.deletedEntries.isEmpty }

        #expect(model.libraryEntries.isEmpty)
        #expect(model.deletedEntries.isEmpty)
        let stillOnDisk = FileManager.default.fileExists(atPath: target.bundleURL.path)
        #expect(stillOnDisk == false)
    }

    @Test("the delete, restore, purge lifecycle ends with the entry gone")
    func deleteRestorePurgeLifecycle() async throws {
        let (model, _) = try makeModel()
        let target = try await model.library.add(transcript: transcript("lifecycle"), audioSource: nil)

        model.deleteEntry(target.id)
        try await pollUntil { model.deletedEntries.map(\.id) == [target.id] }

        model.restoreEntry(target.id)
        try await pollUntil { model.libraryEntries.map(\.id) == [target.id] }

        model.purgeEntry(target.id)
        try await pollUntil { model.libraryEntries.isEmpty && model.deletedEntries.isEmpty }

        #expect(model.libraryEntries.isEmpty)
        #expect(model.deletedEntries.isEmpty)
    }

    private func pollUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
