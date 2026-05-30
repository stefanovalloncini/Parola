import Testing
import Foundation
@testable import ParolaCore

@Suite("LibraryStore", .tags(.fileSystem))
struct LibraryStoreTests {
    private func makeTempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func makeFakeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-store-audio-\(UUID().uuidString).wav")
        try Data("RIFFfakeaudio".utf8).write(to: url)
        return url
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
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        #expect(entry.bundleURL.pathExtension == "parola")
        #expect(FileManager.default.fileExists(atPath: entry.bundleURL.path))

        let entries = await store.list()
        #expect(entries.count == 1)
        #expect(entries.first?.id == entry.id)
    }

    @Test("renaming an entry to a title with a dot keeps the whole title")
    func renamePreservesDottedTitle() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)

        try await store.renameEntry(entry.id, to: "Report v2.0")
        let afterDotted = await store.list()
        #expect(afterDotted.first?.title == "Report v2.0")

        try await store.renameEntry(entry.id, to: "Standup")
        let afterPlain = await store.list()
        #expect(afterPlain.first?.title == "Standup")
    }

    @Test("flush persists the search index so a freshly opened store finds the entry")
    func flushPersistsSearchIndex() async throws {
        let (store, url) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kangaroo invoice quarterly")],
            language: "en",
            modelName: "tiny"
        )
        _ = try await store.add(transcript: transcript, audioSource: audio)
        await store.flush()

        let reopened = LibraryStore(libraryURL: url, extraIndexer: nil)
        let hits = await reopened.search("kangaroo")
        #expect(hits.isEmpty == false)
    }

    @Test("a bundle whose manifest version is newer than the app is dropped from the list")
    func futureVersionBundleDropped() async throws {
        let (store, url) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)

        let manifestURL = entry.bundleURL.appendingPathComponent("manifest.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["version"] = ParolaDocument.Manifest.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        // A fresh store re-scans from disk; the future-version bundle must not appear (it can't open).
        let reopened = LibraryStore(libraryURL: url, extraIndexer: nil)
        let entries = await reopened.list()
        #expect(entries.isEmpty)
    }

    @Test("load round-trips transcript and audio URL")
    func loadRoundTrip() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
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

    @Test("delete sets deletedAt and excludes from list")
    func deleteSetsTimestamp() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.delete(entry.id, at: when)

        let active = await store.list()
        #expect(active.isEmpty)

        let deleted = await store.listDeleted()
        #expect(deleted.count == 1)
        #expect(deleted.first?.deletedAt == when)
    }

    @Test("restore clears deletedAt and returns entry to list")
    func restoreClearsTimestamp() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.delete(entry.id, at: Date())
        try await store.restore(entry.id)

        let active = await store.list()
        #expect(active.count == 1)
        #expect(active.first?.deletedAt == nil)

        let deleted = await store.listDeleted()
        #expect(deleted.isEmpty)
    }

    @Test("purge removes the directory")
    func purgeHardDeletes() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        try await store.purge(entry.id)
        let exists = FileManager.default.fileExists(atPath: entry.bundleURL.path)
        #expect(exists == false)
        let entries = await store.list()
        #expect(entries.isEmpty)
    }

    @Test("purgeDeletedOlderThan removes only sufficiently-old entries")
    func purgeOldDeletedOnly() async throws {
        let (store, _) = try makeTempLibrary()
        let recent = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let old = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let now = Date()
        try await store.delete(recent.id, at: now)
        try await store.delete(old.id, at: now.addingTimeInterval(-31 * 86_400))

        await store.purgeDeletedOlderThan(days: 30, now: now)

        let deleted = await store.listDeleted()
        #expect(deleted.map(\.id).contains(recent.id))
        #expect(deleted.map(\.id).contains(old.id) == false)
        #expect(FileManager.default.fileExists(atPath: recent.bundleURL.path))
        #expect(FileManager.default.fileExists(atPath: old.bundleURL.path) == false)
    }

    @Test("delete invalidates the list cache so the entry no longer appears")
    func deleteInvalidatesCache() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
        _ = await store.list()
        try await store.delete(entry.id, at: Date())
        let active = await store.list()
        #expect(active.isEmpty)
    }

    @Test("loading missing entry throws notFound")
    func loadMissingThrows() async throws {
        let (store, _) = try makeTempLibrary()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.load("does-not-exist")
        }
    }

    @Test("deleting a missing entry throws notFound")
    func deleteMissingThrows() async throws {
        let (store, _) = try makeTempLibrary()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.delete("nope", at: Date())
        }
    }

    @Test("purging a missing entry throws notFound")
    func purgeMissingThrows() async throws {
        let (store, _) = try makeTempLibrary()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.purge("nope")
        }
    }

    @Test("adopt imports an existing .parola bundle without re-transcribing")
    func adoptParolaBundle() async throws {
        let (store, tmp) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-\(UUID().uuidString).parola", isDirectory: true)
        try ParolaDocument.write(
            transcript: makeTranscript(),
            audioURL: audio,
            to: scratch
        )
        let entry = try await store.adopt(parolaBundle: scratch)
        #expect(entry.bundleURL.deletingLastPathComponent() == tmp)
        #expect(entry.bundleURL.pathExtension == "parola")
        let entries = await store.list()
        #expect(entries.count == 1)
    }

    @Test("default add stores transcription category and nil deletedAt")
    func addsDefaultCategory() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(entry.category == .transcription)
        #expect(entry.deletedAt == nil)
    }

    @Test("markOpened persists lastOpenedAt on the manifest")
    func markOpenedPersistsTimestamp() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(entry.lastOpenedAt == nil)

        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.markOpened(id: entry.id, at: when)

        let entries = await store.list()
        let refreshed = try #require(entries.first(where: { $0.id == entry.id }))
        #expect(refreshed.lastOpenedAt == when)
    }

    @Test("manifest without lastOpenedAt decodes with nil default")
    func manifestDecodesMissingLastOpenedAt() throws {
        let json = """
        {
          "version": 1,
          "createdAt": "2025-01-01T00:00:00Z",
          "originalAudioName": "demo.wav",
          "modelName": "tiny",
          "language": "en",
          "category": "transcription"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.lastOpenedAt == nil)
    }

    @Test("updateTranscript stamps updatedAt on the manifest")
    func updateTranscriptStampsUpdatedAt() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(entry.updatedAt == nil)

        let when = Date(timeIntervalSince1970: 1_900_000_000)
        var newTranscript = makeTranscript()
        newTranscript.segments[0].text = "edited"
        try await store.updateTranscript(newTranscript, for: entry.id, at: when)

        let entries = await store.list()
        let refreshed = try #require(entries.first(where: { $0.id == entry.id }))
        #expect(refreshed.updatedAt == when)
    }

    @Test("updateTranscript re-indexes so search reflects the edit")
    func updateTranscriptReindexesSearch() async throws {
        let (store, _) = try makeTempLibrary()
        let original = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "quarterly budget review")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store.add(transcript: original, audioSource: nil)
        #expect(await store.search("quarterly").contains(where: { $0.entryID == entry.id }))

        var edited = original
        edited.segments[0].text = "annual roadmap workshop"
        try await store.updateTranscript(edited, for: entry.id)

        #expect(await store.search("roadmap").contains(where: { $0.entryID == entry.id }))
        #expect(await store.search("quarterly").contains(where: { $0.entryID == entry.id }) == false)
    }

    @Test("search returns active entries and filters soft-deleted")
    func searchFiltersSoftDeleted() async throws {
        let (store, _) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Sprint planning meeting")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store.add(transcript: transcript, audioSource: nil)
        var results = await store.search("sprint")
        #expect(results.contains(where: { $0.entryID == entry.id }))

        try await store.delete(entry.id, at: Date())
        results = await store.search("sprint")
        #expect(results.contains(where: { $0.entryID == entry.id }) == false)

        try await store.restore(entry.id)
        results = await store.search("sprint")
        #expect(results.contains(where: { $0.entryID == entry.id }))
    }

    @Test("adopt rejects a source that is not a valid bundle and leaves nothing behind")
    func adoptInvalidSource() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID().uuidString).parola", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        await #expect(throws: Error.self) {
            try await store.adopt(parolaBundle: scratch)
        }

        let contents = try FileManager.default.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil)
        let bundles = contents.filter { $0.pathExtension == "parola" }
        #expect(bundles.isEmpty)
    }

    @Test("verify reports half-written bundles")
    func verifyDetectsPartials() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let healthy = try await store.add(transcript: makeTranscript(), audioSource: nil)

        let halfWritten = libraryURL.appendingPathComponent("orphan.parola", isDirectory: true)
        try FileManager.default.createDirectory(at: halfWritten, withIntermediateDirectories: true)
        let manifest = """
        { "version": 1, "createdAt": "2030-01-01T00:00:00Z", "originalAudioName": "x.wav", "modelName": "x", "language": "en" }
        """
        try Data(manifest.utf8).write(to: halfWritten.appendingPathComponent("manifest.json"))

        let report = await store.verify()
        #expect(report.healthy.map(\.id).contains(healthy.id))
        #expect(report.problems.count == 1)
        if let problem = report.problems.first {
            #expect(problem.bundleURL.lastPathComponent == "orphan.parola")
            #expect(problem.issue == .missingTranscript)
        }
    }

    @Test("verify flags unreadable manifests")
    func verifyDetectsBrokenManifest() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let broken = libraryURL.appendingPathComponent("broken.parola", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))

        let report = await store.verify()
        #expect(report.problems.contains { $0.issue == .unreadableManifest })
    }

    @Test("verify flags bundles with newer schema versions")
    func verifyFlagsNewerVersion() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let bundle = libraryURL.appendingPathComponent("future.parola", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = """
        { "version": 999, "createdAt": "2030-01-01T00:00:00Z", "originalAudioName": "x.wav", "modelName": "x", "language": "en" }
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("transcript.json"))

        let report = await store.verify()
        if case .versionTooNew(let v) = report.problems.first?.issue {
            #expect(v == 999)
        } else {
            Issue.record("expected versionTooNew issue")
        }
    }
}
