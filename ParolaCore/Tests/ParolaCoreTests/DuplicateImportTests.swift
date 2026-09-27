import Testing
import Foundation
@testable import ParolaCore

@Suite("Duplicate import", .tags(.fileSystem))
struct DuplicateImportTests {
    private func makeTempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func makeAudio(_ bytes: String = "RIFFfakeaudio") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-dedupe-audio-\(UUID().uuidString).wav")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func makeTranscript(model: String = "tiny") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "hi")],
            language: "en",
            modelName: model
        )
    }

    @Test("add stamps the source digest on the manifest")
    func addStampsDigest() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        #expect(entry.sourceDigest == (try SourceDigest.compute(contentsOf: audio)))
    }

    @Test("a transcript imported without media carries no digest")
    func noAudioNoDigest() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(entry.sourceDigest == nil)
    }

    @Test("a digest the caller already computed is used as it stands")
    func callerSuppliedDigest() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let entry = try await store.add(
            transcript: makeTranscript(), audioSource: audio, sourceDigest: "abc123"
        )
        #expect(entry.sourceDigest == "abc123")
    }

    @Test("the same file transcribed twice lands on the same digest")
    func sameFileSameDigest() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let first = try await store.add(transcript: makeTranscript(model: "tiny"), audioSource: audio)
        let second = try await store.add(transcript: makeTranscript(model: "turbo"), audioSource: audio)
        #expect(first.sourceDigest == second.sourceDigest)
        #expect(first.id != second.id)
    }

    @Test("findEntry matches on the digest and returns the newest")
    func findEntryReturnsNewest() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let first = try await store.add(transcript: makeTranscript(), audioSource: audio)
        try ParolaDocument.updateManifest(at: first.bundleURL) {
            $0.createdAt = Date(timeIntervalSince1970: 1_000_000)
        }
        let second = try await store.add(transcript: makeTranscript(), audioSource: audio)
        let digest = try #require(second.sourceDigest)

        let found = await store.findEntry(digest: digest)
        #expect(found?.id == second.id)
    }

    @Test("findEntry ignores a different file and an empty digest")
    func findEntryMisses() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        _ = try await store.add(transcript: makeTranscript(), audioSource: audio)

        #expect(await store.findEntry(digest: "not-a-digest") == nil)
        #expect(await store.findEntry(digest: "") == nil)
    }

    @Test("a deleted entry stops counting as a duplicate")
    func deletedEntryIsNotADuplicate() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        let digest = try #require(entry.sourceDigest)
        #expect(await store.findEntry(digest: digest) != nil)

        try await store.delete(entry.id)
        #expect(await store.findEntry(digest: digest) == nil)

        try await store.restore(entry.id)
        #expect(await store.findEntry(digest: digest)?.id == entry.id)
    }

    @Test("a test process is recognised as one, so the shared store stays out of reach")
    func testProcessIsDetected() {
        #expect(LibraryStore.isTestProcess)
    }

    @Test("a manifest written before digests decodes without one")
    func oldManifestDecodes() throws {
        let json = """
        {
          "version": 1,
          "createdAt": "2025-01-01T00:00:00Z",
          "originalAudioName": "demo.wav",
          "modelName": "tiny",
          "language": "en"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.sourceDigest == nil)
        #expect(ParolaDocument.Manifest.currentVersion == 2)
    }

    @Test("verify fills the digest of a bundle that predates it")
    func verifyFillsDigest() async throws {
        let (store, library) = try makeTempLibrary()
        let audio = try makeAudio("RIFFolderaudio")
        defer { try? FileManager.default.removeItem(at: audio) }

        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        try ParolaDocument.updateManifest(at: entry.bundleURL) { $0.sourceDigest = nil }
        #expect(LibraryStore.verifySync(at: library).healthy.first?.sourceDigest != nil)

        let reread = try ParolaDocument.read(at: entry.bundleURL)
        #expect(reread.manifest.sourceDigest == (try SourceDigest.compute(contentsOf: audio)))
    }

    @Test("the backfill fills bundles the reindex walked past")
    func backfillFillsDigest() async throws {
        let (seed, library) = try makeTempLibrary()
        let audio = try makeAudio("RIFFbackfill")
        defer { try? FileManager.default.removeItem(at: audio) }
        let entry = try await seed.add(transcript: makeTranscript(), audioSource: audio)
        try ParolaDocument.updateManifest(at: entry.bundleURL) { $0.sourceDigest = nil }
        try? FileManager.default.removeItem(at: library.appendingPathComponent(".search-index", isDirectory: true))

        let store = LibraryStore(libraryURL: library, extraIndexer: nil)
        _ = await store.search("hi")
        await store.waitForSourceDigestBackfill()

        let digest = try #require(try SourceDigest.compute(contentsOf: audio))
        #expect(await store.findEntry(digest: digest)?.id == entry.id)
    }

    @Test("the backfill fills a bundle whose index is already current")
    func backfillRunsOverACurrentIndex() async throws {
        let (seed, library) = try makeTempLibrary()
        let audio = try makeAudio("RIFFcurrentindex")
        defer { try? FileManager.default.removeItem(at: audio) }
        let entry = try await seed.add(transcript: makeTranscript(), audioSource: audio)
        await seed.flush()
        try ParolaDocument.updateManifest(at: entry.bundleURL) { $0.sourceDigest = nil }

        let store = LibraryStore(libraryURL: library, extraIndexer: nil)
        await store.warmSearchIndex()
        await store.waitForSourceDigestBackfill()

        let digest = try #require(try SourceDigest.compute(contentsOf: audio))
        #expect(try ParolaDocument.read(at: entry.bundleURL).manifest.sourceDigest == digest)
        #expect(await store.findEntry(digest: digest)?.id == entry.id)
    }
}
