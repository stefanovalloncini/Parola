import Testing
import Foundation
@testable import ParolaCore

@Suite("LibraryStore load cache", .tags(.fileSystem))
struct LibraryLoadCacheTests {
    private func makeStore() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func makeTranscript(_ text: String, segments count: Int = 1) -> Transcript {
        Transcript(
            segments: (0..<count).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 0.5, text: text)
            },
            language: "en",
            modelName: "tiny"
        )
    }

    /// Rewrites transcript.json behind the actor's back, so a load still answering with the old text
    /// can only have taken it from the cache.
    private func rewriteOnDisk(_ entry: LibraryEntry, text: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(makeTranscript(text))
        try data.write(to: entry.bundleURL.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func firstText(_ loaded: LoadedEntry) -> String? {
        loaded.document.transcript.segments.first?.text
    }

    @Test("a repeat load of the same entry answers from the cache")
    func repeatLoadSkipsDisk() async throws {
        let (store, _) = try makeStore()
        let entry = try await store.add(transcript: makeTranscript("original"), audioSource: nil)
        #expect(firstText(try await store.load(entry.id)) == "original")

        try rewriteOnDisk(entry, text: "on disk")

        #expect(firstText(try await store.load(entry.id)) == "original")
    }

    @Test("alternating between two entries re-reads neither")
    func alternatingLoadsStayCached() async throws {
        let (store, _) = try makeStore()
        let a = try await store.add(transcript: makeTranscript("a"), audioSource: nil)
        let b = try await store.add(transcript: makeTranscript("b"), audioSource: nil)
        _ = try await store.load(a.id)
        _ = try await store.load(b.id)

        try rewriteOnDisk(a, text: "a on disk")
        try rewriteOnDisk(b, text: "b on disk")

        #expect(firstText(try await store.load(a.id)) == "a")
        #expect(firstText(try await store.load(b.id)) == "b")
    }

    @Test("a fourth entry evicts the least recently loaded one")
    func fourthLoadEvictsTheOldest() async throws {
        let (store, _) = try makeStore()
        var entries: [LibraryEntry] = []
        for i in 0..<4 {
            entries.append(try await store.add(transcript: makeTranscript("entry \(i)"), audioSource: nil))
        }
        for entry in entries {
            _ = try await store.load(entry.id)
        }
        for entry in entries {
            try rewriteOnDisk(entry, text: "\(entry.id) on disk")
        }

        #expect(firstText(try await store.load(entries[0].id)) == "\(entries[0].id) on disk")
        #expect(firstText(try await store.load(entries[3].id)) == "entry 3")
    }

    @Test("updateTranscript drops the cached copy of that entry and no other")
    func updateTranscriptInvalidatesOneSlot() async throws {
        let (store, _) = try makeStore()
        let a = try await store.add(transcript: makeTranscript("a"), audioSource: nil)
        let b = try await store.add(transcript: makeTranscript("b"), audioSource: nil)
        _ = try await store.load(a.id)
        _ = try await store.load(b.id)

        try await store.updateTranscript(makeTranscript("a edited"), for: a.id)
        try rewriteOnDisk(b, text: "b on disk")

        #expect(firstText(try await store.load(a.id)) == "a edited")
        #expect(firstText(try await store.load(b.id)) == "b")
    }

    @Test("a manifest edit refreshes the cached entry without re-reading the transcript")
    func manifestEditPatchesTheCachedEntry() async throws {
        let (store, _) = try makeStore()
        let entry = try await store.add(transcript: makeTranscript("original"), audioSource: nil)
        _ = try await store.load(entry.id)
        try rewriteOnDisk(entry, text: "on disk")

        try await store.renameEntry(entry.id, to: "Standup")

        let loaded = try await store.load(entry.id)
        #expect(loaded.entry.title == "Standup")
        #expect(firstText(loaded) == "original")
    }

    @Test("a load in flight when updateTranscript lands never answers with the pre-update transcript")
    func loadRacingUpdateSeesTheUpdate() async throws {
        let (store, _) = try makeStore()
        // Big enough that the off-actor decode cannot finish inside the head start the update gets.
        let entry = try await store.add(transcript: makeTranscript("original 0", segments: 20_000), audioSource: nil)

        for i in 0..<2 {
            if i > 0 {
                try await store.updateTranscript(makeTranscript("original \(i)", segments: 20_000), for: entry.id)
            }
            let loading = Task { try await store.load(entry.id) }
            try await Task.sleep(for: .milliseconds(1))
            try await store.updateTranscript(makeTranscript("edited \(i)"), for: entry.id)

            #expect(firstText(try await loading.value) == "edited \(i)")
            #expect(firstText(try await store.load(entry.id)) == "edited \(i)")
        }
    }
}
