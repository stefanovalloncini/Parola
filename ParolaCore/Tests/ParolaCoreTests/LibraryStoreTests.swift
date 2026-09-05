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

    private struct HangingIndexer: LibraryIndexer {
        func index(id: String, title: String, text: String, createdAt: Date) async {
            try? await Task.sleep(for: .seconds(3600))
        }
        func deindex(id: String) async {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    @Test("a stalled extra indexer never blocks add")
    func addSurvivesHangingExtraIndexer() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = LibraryStore(libraryURL: tmp, extraIndexer: HangingIndexer())
        let audio = try makeFakeAudio()
        let transcript = makeTranscript()

        let added: LibraryEntry? = try await withThrowingTaskGroup(of: LibraryEntry?.self) { group in
            group.addTask { try await store.add(transcript: transcript, audioSource: audio) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(added != nil, "add() must return even when the extra indexer stalls")
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

    @Test("dropCaches makes a wiped library directory read empty instead of resurrecting it")
    func dropCachesAfterDirectoryWipe() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)

        #expect(await store.list().count == 1)
        #expect(try await store.load(entry.id).entry.id == entry.id)

        try FileManager.default.removeItem(at: libraryURL)

        #expect(await store.list().count == 1)

        await store.dropCaches()

        #expect(await store.list().isEmpty)
        await #expect(throws: LibraryStore.LibraryError.self) { try await store.load(entry.id) }
    }

    @Test("a mutation landing during the list scan never empties the list")
    func mutationDuringScanKeepsListPopulated() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        for i in 0..<200 {
            try ParolaDocument.write(
                transcript: makeTranscript(),
                audioURL: nil,
                to: libraryURL.appendingPathComponent(String(format: "entry-%03d", i))
            )
        }
        let victim = try #require(await store.list().first)

        for _ in 0..<8 {
            await store.dropCaches()
            let listing = Task { await store.list() }
            try await Task.sleep(for: .milliseconds(1))
            try await store.setPinned(true, for: victim.id)
            #expect(await listing.value.count == 200)
        }
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

    @Test("setLabels trims, drops empties, and dedupes")
    func setLabelsNormalizes() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)

        try await store.setLabels(["work", "work", "  work  ", "", "done"], for: entry.id)

        let entries = await store.list()
        #expect(entries.first?.labels == ["work", "done"])
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

    @Test("load round-trips a transcript's chat history, timestamps included")
    func loadPreservesChatHistory() async throws {
        let (store, _) = try makeTempLibrary()
        let conversation = [
            ChatMessage(role: .user, text: "What's the main point?",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ChatMessage(role: .assistant, text: "Two people say hi.",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_042)),
        ]
        var transcript = makeTranscript()
        transcript.chatHistory = conversation
        let entry = try await store.add(transcript: transcript, audioSource: nil)

        let loaded = try await store.load(entry.id).document.transcript.chatHistory
        #expect(loaded == conversation)
    }

    @Test("updateTranscript persists chat recorded after the initial save")
    func updateTranscriptPersistsChatHistory() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(try await store.load(entry.id).document.transcript.chatHistory == nil)

        let conversation = [
            ChatMessage(role: .user, text: "Summarize it.",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ChatMessage(role: .assistant, text: "A short greeting.",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_140)),
        ]
        var edited = makeTranscript()
        edited.chatHistory = conversation
        try await store.updateTranscript(edited, for: entry.id)

        let reloaded = try await store.load(entry.id).document.transcript.chatHistory
        #expect(reloaded == conversation)
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

    /// Removes the bundle from disk after the mutation: a patched cache still answers from memory,
    /// a full rescan would come back empty.
    private func listAfterMutation(
        _ mutate: (LibraryStore, LibraryEntry.ID) async throws -> Void
    ) async throws -> [LibraryEntry] {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        _ = await store.list()
        try await mutate(store, entry.id)
        try FileManager.default.removeItem(at: entry.bundleURL)
        return await store.list()
    }

    @Test("a manifest edit patches the list cache instead of rescanning every bundle")
    func manifestEditsPatchTheListCache() async throws {
        #expect(try await listAfterMutation { try await $0.setPinned(true, for: $1) }.first?.pinned == true)
        #expect(try await listAfterMutation { try await $0.setCategory(.meeting, for: $1) }.first?.category == .meeting)
        #expect(try await listAfterMutation { try await $0.setLabels(["work"], for: $1) }.first?.labels == ["work"])
        #expect(try await listAfterMutation { try await $0.renameEntry($1, to: "Standup") }.first?.title == "Standup")
        #expect(try await listAfterMutation {
            try await $0.setSegmentNote("kanban", segmentID: 0, for: $1)
        }.first?.note(forSegment: 0) == "kanban")

        let when = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(try await listAfterMutation {
            var edited = makeTranscript()
            edited.segments[0].text = "edited"
            try await $0.updateTranscript(edited, for: $1, at: when)
        }.first?.updatedAt == when)
    }

    @Test("delete moves the entry into the cached trash list in deletion order")
    func deletePatchesBothCaches() async throws {
        let (store, _) = try makeTempLibrary()
        let older = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let newer = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.delete(newer.id, at: Date(timeIntervalSince1970: 2_000))
        _ = await store.list()
        _ = await store.listDeleted()

        try await store.delete(older.id, at: Date(timeIntervalSince1970: 1_000))
        try FileManager.default.removeItem(at: older.bundleURL)

        #expect(await store.list().isEmpty)
        #expect(await store.listDeleted().map(\.id) == [newer.id, older.id])
    }

    @Test("restore returns the entry to its place in the cached list")
    func restorePatchesBothCaches() async throws {
        let (store, _) = try makeTempLibrary()
        let older = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let newer = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.delete(older.id, at: Date())
        _ = await store.list()
        _ = await store.listDeleted()

        try await store.restore(older.id)
        try FileManager.default.removeItem(at: newer.bundleURL)

        #expect(await store.list().map(\.id) == [newer.id, older.id])
        #expect(await store.listDeleted().isEmpty)
    }

    @Test("purge drops only the purged entry from the cached list")
    func purgePatchesCaches() async throws {
        let (store, _) = try makeTempLibrary()
        let first = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let second = try await store.add(transcript: makeTranscript(), audioSource: nil)
        _ = await store.list()

        try await store.purge(first.id)
        try FileManager.default.removeItem(at: second.bundleURL)

        #expect(await store.list().map(\.id) == [second.id])
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
        let staging = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(staging.isEmpty)
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

    @Test("blank rows in an entry written before the assembly-time drop disappear on load")
    func loadDropsBlankSegments() async throws {
        let (store, _) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "hi"),
                TranscriptSegment(id: 1, start: 6.18, end: 7.58, text: ""),
                TranscriptSegment(id: 2, start: 12, end: 13, text: "there"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store.add(transcript: transcript, audioSource: nil)

        let loaded = try await store.load(entry.id)

        #expect(loaded.document.transcript.segments.map(\.text) == ["hi", "there"])
        #expect(loaded.document.transcript.segments.map(\.id) == [0, 2], "notes are keyed by segment id")
    }

    @Test("a note keyed to a segment after a blank row still lands on that segment")
    func loadKeepsNotesOnTheirSegments() async throws {
        let (store, _) = try makeTempLibrary()
        let segments = (0...8).map { index in
            TranscriptSegment(
                id: index,
                start: Double(index),
                end: Double(index) + 0.9,
                text: index == 3 ? "" : "line \(index)"
            )
        }
        let entry = try await store.add(
            transcript: Transcript(segments: segments, language: "en", modelName: "tiny"),
            audioSource: nil
        )
        try await store.setSegmentNote("check this", segmentID: 7, for: entry.id)

        let loaded = try await store.load(entry.id)

        let noted = loaded.document.transcript.segments.first { loaded.entry.note(forSegment: $0.id) != nil }
        #expect(noted?.text == "line 7")
    }

    /// Read through FileManager, not URL.resourceValues: URL caches the first answer, so a second
    /// read of the same URL would report the file as untouched however often it was rewritten.
    private func snapshotWrittenAt(_ dir: URL) throws -> Date? {
        let url = dir.appendingPathComponent(".search-index.json")
        return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func makeTempLibraryDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func seedBundle(in dir: URL, named name: String, text: String) throws {
        _ = try ParolaDocument.write(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "tiny"
            ),
            audioURL: nil,
            to: dir.appendingPathComponent(name)
        )
    }

    @Test("a bundle written straight into the library folder turns up in search")
    func indexesBundlesAddedBehindTheApp() async throws {
        let (store, dir) = try makeTempLibrary()
        _ = try await store.add(transcript: makeTranscript(), audioSource: nil)
        _ = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(await store.search("zzyzxmarker").isEmpty)
        await store.flush()
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker in the minutes")

        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)

        #expect(await relaunched.search("zzyzxmarker").map(\.entryID) == ["seeded"])
    }

    @Test("a bundle removed behind the app stops matching")
    func dropsBundlesRemovedBehindTheApp() async throws {
        let dir = try makeTempLibraryDirectory()
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker in the minutes")
        let staged = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await staged.search("zzyzxmarker").count == 1)
        await staged.flush()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("seeded.parola"))
        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)

        #expect(await relaunched.search("zzyzxmarker").isEmpty)
    }

    @Test("a bundle rewritten behind the app is reindexed from its new transcript")
    func reindexesBundlesRewrittenBehindTheApp() async throws {
        let dir = try makeTempLibraryDirectory()
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker in the minutes")
        let staged = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await staged.search("zzyzxmarker").count == 1)
        await staged.flush()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("seeded.parola"))
        try seedBundle(in: dir, named: "seeded", text: "qqxwmarker in the minutes")
        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)

        #expect(await relaunched.search("zzyzxmarker").isEmpty)
        #expect(await relaunched.search("qqxwmarker").count == 1)
    }

    @Test("a library nothing touched is not reindexed on the next launch")
    func leavesAFreshIndexAlone() async throws {
        let (store, dir) = try makeTempLibrary()
        _ = try await store.add(transcript: makeTranscript(), audioSource: nil)
        await store.flush()
        let snapshot = dir.appendingPathComponent(".search-index.json")
        let before = try #require(
            try snapshot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await relaunched.search("hi").count == 1)
        await relaunched.flush()

        let after = try snapshot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(after == before, "a rebuild would rewrite the snapshot")
    }

    @Test("a failed manifest write leaves no pre-edit document in the cache")
    func updateTranscriptFailureDropsStaleCache() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(try await store.load(entry.id).document.transcript.segments.first?.text == "hi")

        let manifestURL = entry.bundleURL.appendingPathComponent("manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        try Data("not json".utf8).write(to: manifestURL)

        var edited = makeTranscript()
        edited.segments[0].text = "edited"
        await #expect(throws: (any Error).self) {
            try await store.updateTranscript(edited, for: entry.id)
        }

        try manifest.write(to: manifestURL)
        let reloaded = try await store.load(entry.id)
        #expect(reloaded.document.transcript.segments.first?.text == "edited")
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

    @Test("summary text, segment notes, and speaker names are searchable")
    func searchFindsSummaryNotesSpeakers() async throws {
        let (store, _) = try makeTempLibrary()
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "Good morning everyone", speaker: "Marta")],
            language: "en",
            modelName: "tiny"
        )
        transcript.summary = Summary(text: "Renewal deadlines are slipping")
        let entry = try await store.add(transcript: transcript, audioSource: nil)
        try await store.setSegmentNote("check the kanban board", segmentID: 0, for: entry.id)

        #expect(await store.search("renewal").contains(where: { $0.entryID == entry.id }))
        #expect(await store.search("marta").contains(where: { $0.entryID == entry.id }))
        #expect(await store.search("kanban").contains(where: { $0.entryID == entry.id }))
    }

    @Test("re-indexing an open entry matches search on title, note, and transcript alike")
    func reindexFromLoadedDocument() async throws {
        let (store, _) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kryptonite meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store.add(transcript: transcript, audioSource: nil)
        _ = try await store.load(entry.id)

        try await store.renameEntry(entry.id, to: "Standup")
        try await store.setSegmentNote("kanban board", segmentID: 0, for: entry.id)

        #expect(await store.search("standup").contains { $0.entryID == entry.id })
        #expect(await store.search("kanban").contains { $0.entryID == entry.id })
        #expect(await store.search("kryptonite").contains { $0.entryID == entry.id })
    }

    @Test("clearing a segment note removes its tokens from search")
    func clearingNoteDeindexesIt() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.setSegmentNote("check the kanban board", segmentID: 0, for: entry.id)
        #expect(await store.search("kanban").contains(where: { $0.entryID == entry.id }))

        try await store.setSegmentNote(nil, segmentID: 0, for: entry.id)
        #expect(await store.search("kanban").isEmpty)
    }

    @Test("a v2 index snapshot is rebuilt with summary, note, and speaker tokens")
    func v2SnapshotRebuildRegeneratesRicherTokens() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "kryptonite meeting notes", speaker: "Ines")],
            language: "en",
            modelName: "tiny"
        )
        transcript.summary = Summary(text: "Renewal deadlines")
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        try await store1.setSegmentNote("check the kanban board", segmentID: 0, for: entry.id)
        await store1.flush()

        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        let v2 = """
        {"version":2,"entries":{"\(entry.id)":{"title":"Old","excerpt":"kryptonite meeting notes","tokens":["kryptonite","meeting","notes"]}}}
        """
        try Data(v2.utf8).write(to: indexURL)

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store2.search("renewal").contains(where: { $0.entryID == entry.id }))
        #expect(await store2.search("kanban").contains(where: { $0.entryID == entry.id }))
        #expect(await store2.search("ines").contains(where: { $0.entryID == entry.id }))
    }

    @Test("a stale old-format index snapshot is discarded and rebuilt from bundles")
    func staleIndexSnapshotRebuild() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kryptonite meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        await store1.flush()

        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        let oldFormat = """
        {"entries":{"ghost":{"id":"ghost","title":"Ghost","text":"phantom words"}},"inverted":{"phantom":["ghost"],"words":["ghost"]}}
        """
        try Data(oldFormat.utf8).write(to: indexURL)

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let matches = await store2.search("kryptonite")
        #expect(matches.contains(where: { $0.entryID == entry.id }))
        let ghost = await store2.search("phantom")
        #expect(ghost.isEmpty)
    }

    @Test("a version-3 index snapshot is rebuilt from the bundles")
    func v3SnapshotRebuild() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kryptonite meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        await store1.flush()

        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        let v3 = """
        {"version":3,"entries":{"\(entry.id)":{"title":"Old","excerpt":"phantom","tokens":["phantom"]}}}
        """
        try Data(v3.utf8).write(to: indexURL)

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store2.search("kryptonite").contains(where: { $0.entryID == entry.id }))
        #expect(await store2.search("phantom").isEmpty)
    }

    @Test("a library whose index snapshot is gone rebuilds from the bundles")
    func missingIndexSnapshotRebuild() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kryptonite meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        await store1.flush()

        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        try FileManager.default.removeItem(at: indexURL)

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store2.search("kryptonite").contains(where: { $0.entryID == entry.id }))

        let raw = try #require(String(data: Data(contentsOf: indexURL), encoding: .utf8))
        #expect(raw.contains("kryptonite"))

        let store3 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store3.search("kryptonite").contains(where: { $0.entryID == entry.id }))
    }

    @Test("an empty library with no snapshot searches without error")
    func missingIndexSnapshotEmptyLibrary() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        #expect(await store.search("kryptonite").isEmpty)
        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
    }

    @Test("a library directory that will not list writes no empty snapshot")
    func unreadableLibraryWritesNoSnapshot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }
        // Write and search but no read: the listing fails while a snapshot could still be written there.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: tmp.path)

        let store = LibraryStore(libraryURL: tmp, extraIndexer: nil)
        #expect(await store.search("kryptonite").isEmpty)
        let indexURL = tmp.appendingPathComponent(".search-index.json")
        #expect(FileManager.default.fileExists(atPath: indexURL.path) == false)
    }

    @Test("search on a fresh store instance finds previously indexed entries")
    func coldStoreSearch() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kryptonite meeting notes")],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        await store1.flush()

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let matches = await store2.search("kryptonite")
        #expect(matches.contains(where: { $0.entryID == entry.id }))
    }

    @Test("adopt rejects a source that is not a valid bundle and leaves nothing behind")
    func adoptInvalidSource() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID().uuidString).parola", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        await #expect(throws: ParolaError.self) {
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
