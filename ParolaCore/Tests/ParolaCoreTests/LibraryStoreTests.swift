import Testing
import Foundation
import os
@testable import ParolaCore

@Suite("LibraryStore", .tags(.fileSystem))
struct LibraryStoreTests {
    private func makeTempLibrary(
        didWriteBundle: (@Sendable () -> Void)? = nil
    ) throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = LibraryStore(
            storeAt: tmp, extraIndexer: nil,
            seams: LibraryStore.TestSeams(didWriteBundle: didWriteBundle)
        )
        return (store, tmp)
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

    @Test("an add that consumes its audio moves it into the bundle; a plain add copies")
    func consumedAudioIsMoved() async throws {
        let (store, _) = try makeTempLibrary()
        let consumed = try makeFakeAudio()
        let copied = try makeFakeAudio()
        defer { try? FileManager.default.removeItem(at: copied) }

        let moved = try await store.add(transcript: makeTranscript(), audioSource: consumed, consumesAudio: true)
        let kept = try await store.add(transcript: makeTranscript(), audioSource: copied)

        #expect(!FileManager.default.fileExists(atPath: consumed.path))
        #expect(FileManager.default.fileExists(atPath: copied.path))
        for entry in [moved, kept] {
            let audio = try #require(try await store.load(entry.id).document.audioURL)
            #expect(try Data(contentsOf: audio) == Data("RIFFfakeaudio".utf8))
        }
    }

    @Test("chat history is never searchable")
    func chatHistoryIsNotIndexed() async throws {
        let (store, _) = try makeTempLibrary()
        var transcript = makeTranscript()
        transcript.chatHistory = [
            ChatMessage(role: .user, text: "zzyzxchat"),
            ChatMessage(role: .assistant, text: "zzyzxreply")
        ]
        let entry = try await store.add(transcript: transcript, audioSource: nil)

        #expect(await store.search("zzyzxchat").isEmpty)
        #expect(await store.search("zzyzxreply").isEmpty)
        #expect(await store.search("hi").contains(where: { $0.entryID == entry.id }))
    }

    @Test("a translation is written to the transcript and cleared again")
    func translationPersistsAndClears() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "ciao"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "mock"
        )

        try await store.setTranslation(translation, for: entry.id)
        #expect(try await store.load(entry.id).document.transcript.translation == translation)

        try await store.setTranslation(nil, for: entry.id)
        #expect(try await store.load(entry.id).document.transcript.translation == nil)
    }

    @Test("a translation does not revert a transcript edit it never read")
    func setTranslationKeepsAnEditItNeverSaw() async throws {
        let (store, tmp) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        _ = try await store.load(entry.id)

        // What another writer's finished write looks like to a reader holding an older copy.
        var edited = makeTranscript()
        edited.segments[0].text = "edited elsewhere"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(edited).write(
            to: tmp.appendingPathComponent("\(entry.id).parola", isDirectory: true)
                .appendingPathComponent("transcript.json"),
            options: .atomic
        )

        try await store.setTranslation(
            TranscriptTranslation(
                targetLanguage: "it",
                segments: [0: "ciao"],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                provider: "mock"
            ),
            for: entry.id
        )

        let after = try await store.load(entry.id).document.transcript
        #expect(after.segments.first?.text == "edited elsewhere")
        #expect(after.translation?.targetLanguage == "it")
    }

    @Test("two transcript changes in flight at once both land")
    func concurrentTranscriptMutationsBothLand() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "ciao"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "mock"
        )

        async let first = store.mutateTranscript(for: entry.id, reindex: false) { $0.translation = translation }
        async let second = store.mutateTranscript(for: entry.id, reindex: false) {
            $0.chatHistory = [ChatMessage(role: .user, text: "who spoke first?")]
        }
        _ = try await [first, second]

        let after = try await store.load(entry.id).document.transcript
        #expect(after.translation == translation)
        #expect(after.chatHistory?.map(\.text) == ["who spoke first?"])
    }

    @Test("a transcript change that changes nothing is not written")
    func unchangedTranscriptIsNotWritten() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let before = try await store.load(entry.id).entry.updatedAt

        try await store.mutateTranscript(for: entry.id) { _ in }

        #expect(try await store.load(entry.id).entry.updatedAt == before)
    }

    @Test("a translation is never searchable")
    func translationIsNotIndexed() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)

        try await store.setTranslation(
            TranscriptTranslation(
                targetLanguage: "it",
                segments: [0: "zzyzxtranslated"],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                provider: "mock"
            ),
            for: entry.id
        )

        #expect(await store.search("zzyzxtranslated").isEmpty)
    }

    @Test("empty library lists nothing")
    func emptyList() async throws {
        let (store, _) = try makeTempLibrary()
        let entries = await store.list()
        #expect(entries.isEmpty)
    }

    @Test("card metadata is written to the manifest and searchable")
    func cardMetadataWrittenAndIndexed() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: makeFakeAudio(), category: .transcription)
        try await store.setCardMetadata(aiTitle: "Quarterly sync", shortSummary: "Budget zebra review.", for: entry.id)
        let reloaded = try #require(await store.list().first { $0.id == entry.id })
        #expect(reloaded.aiTitle == "Quarterly sync")
        #expect(reloaded.shortSummary == "Budget zebra review.")
        let hits = await store.search("zebra")
        #expect(hits.map(\.entryID).contains(entry.id))
        try await store.setCardMetadata(aiTitle: nil, shortSummary: nil, for: entry.id)
        #expect(await store.list().first { $0.id == entry.id }?.aiTitle == nil)
    }

    @Test("a new card swaps the old one's words in search and hands back the entry")
    func cardMetadataReplacesItsSearchWords() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: makeFakeAudio(), category: .transcription)
        let bodyWord = try #require(makeTranscript().text.split(separator: " ").first.map(String.init))

        let first = try await store.setCardMetadata(aiTitle: "Quarterly zebra", shortSummary: nil, for: entry.id)
        #expect(first.aiTitle == "Quarterly zebra")
        #expect(await store.search("zebra").map(\.entryID) == [entry.id])

        let second = try await store.setCardMetadata(aiTitle: "Annual okapi", shortSummary: "Mostly \(bodyWord).", for: entry.id)
        #expect(second.aiTitle == "Annual okapi")
        #expect(await store.search("zebra").isEmpty)
        #expect(await store.search("okapi").map(\.entryID) == [entry.id])

        try await store.setCardMetadata(aiTitle: nil, shortSummary: nil, for: entry.id)
        #expect(await store.search("okapi").isEmpty)
        let bodyHit = try #require(await store.search(bodyWord).first { $0.entryID == entry.id })
        #expect(bodyHit.firstHit != nil)
    }

    @Test("a re-run re-stamps the engine and language the rows name")
    func transcriptionDetailsFollowTheRerun() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: makeFakeAudio(), category: .transcription)
        try await store.setLabels(["keep"], for: entry.id)

        try await store.setTranscriptionDetails(modelName: "openai_whisper-large-v3_turbo", language: "it", for: entry.id)

        let reloaded = try #require(await store.list().first { $0.id == entry.id })
        #expect(reloaded.modelName == "openai_whisper-large-v3_turbo")
        #expect(reloaded.language == "it")
        #expect(reloaded.labels == ["keep"])
        #expect(reloaded.title == entry.title)
    }

    @Test("favorites toggle per segment and can be replaced wholesale")
    func favoritesPersist() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: makeFakeAudio(), category: .transcription)
        try await store.setSegmentFavorite(true, segmentID: 2, for: entry.id)
        try await store.setSegmentFavorite(true, segmentID: 0, for: entry.id)
        #expect(await store.list().first { $0.id == entry.id }?.favoriteSegments == [0, 2])
        try await store.setSegmentFavorite(false, segmentID: 2, for: entry.id)
        #expect(await store.list().first { $0.id == entry.id }?.favoriteSegments == [0])
        try await store.setFavoriteSegments([5, 1], for: entry.id)
        #expect(await store.list().first { $0.id == entry.id }?.favoriteSegments == [1, 5])
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

    /// A bridged id is Unicode-normalised through the bridge on every SwiftUI list-diff hash.
    @Test("a listed entry's id is a native Swift string, not a bridged NSString")
    func listedIDsAreNativeStrings() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "20260921T101530-A1B2C3D4-1111-2222-3333-444455556666"
        try seedBundle(in: dir, named: name, text: "minutes of the meeting")
        let store = LibraryStore(libraryURL: dir, extraIndexer: nil)

        let entry = try #require(await store.list().first)
        let bundleName = entry.bundleURL.lastPathComponent
        #expect(entry.id == (bundleName as NSString).deletingPathExtension)
        #expect(entry.id == name)
        #expect(entry.id.utf8.withContiguousStorageIfAvailable { _ in true } == true)

        let loaded = try await store.load(name).entry
        #expect(loaded.id == name)
        #expect(loaded.id.utf8.withContiguousStorageIfAvailable { _ in true } == true)

        let verified = try #require(await store.verify().healthy.first)
        #expect(verified.id == name)
        #expect(verified.id.utf8.withContiguousStorageIfAvailable { _ in true } == true)
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

    @Test("a search hit past 200 characters gets a real snippet, end to end through the store")
    func searchFarIntoTranscriptGetsRealSnippet() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let filler = "lorem ipsum dolor sit amet consectetur adipiscing elit"
        var segments = (0..<90).map { i in
            TranscriptSegment(id: i, start: Double(i), end: Double(i) + 0.5, text: filler)
        }
        segments.append(TranscriptSegment(id: 90, start: 90, end: 90.5, text: "zzyzxmarker tail"))
        let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")
        _ = try await store.add(transcript: transcript, audioSource: audio)
        #expect(transcript.text.distance(
            from: transcript.text.startIndex,
            to: try #require(transcript.text.range(of: "zzyzxmarker")).lowerBound
        ) > 200)

        let hits = await store.search("zzyzxmarker")
        let hit = try #require(hits.first)
        #expect(hit.snippet.lowercased().contains("zzyzxmarker"))
        #expect(hit.highlights.isEmpty == false)
    }

    /// Fix round 1, R1.4 finding #5: the query path must never read a bundle off disk. This times
    /// `search` against a scratch library holding one entry the size of Stefano's 1h42m real file
    /// (961 segments, ~64,000 characters) to show the in-memory v9 index keeps it fast.
    @Test("search stays fast on a scratch library with one multi-hour entry")
    func searchQueryPathTimingOnAMultiHourEntry() async throws {
        let (store, _) = try makeTempLibrary()
        let audio = try makeFakeAudio()
        let words = "grazie a tutti per la vostra pazienza durante questa lunga riunione di oggi pomeriggio"
        var segments = (0..<960).map { i in
            TranscriptSegment(id: i, start: Double(i) * 6, end: Double(i) * 6 + 5, text: words)
        }
        segments.append(TranscriptSegment(id: 960, start: 5760, end: 5765, text: "zzyzxmarker closing remarks"))
        let transcript = Transcript(segments: segments, language: "it", modelName: "tiny")
        #expect(transcript.text.count > 60_000)
        _ = try await store.add(transcript: transcript, audioSource: audio)
        await store.flush()

        let clock = ContinuousClock()
        let start = clock.now
        let hits = await store.search("zzyzxmarker")
        let elapsed = clock.now - start

        #expect(hits.first?.snippet.lowercased().contains("zzyzxmarker") == true)
        print("search-query-path-timing: \(transcript.text.count) chars, 961 segments, elapsed \(elapsed)")
        #expect(elapsed < .milliseconds(50))
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

        let result = await store.purgeDeletedOlderThan(days: 30, now: now)

        #expect(result.purgedIDs == [old.id])
        #expect(result.purged == 1)
        #expect(result.failed == 0)
        let deleted = await store.listDeleted()
        #expect(deleted.map(\.id).contains(recent.id))
        #expect(deleted.map(\.id).contains(old.id) == false)
        #expect(FileManager.default.fileExists(atPath: recent.bundleURL.path))
        #expect(FileManager.default.fileExists(atPath: old.bundleURL.path) == false)
    }

    @Test("a purge over warm caches neither rescans nor drops them, and takes out what it removed")
    func purgeKeepsWarmCaches() async throws {
        let (store, tmp) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kept = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let old = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let now = Date()
        try await store.delete(old.id, at: now.addingTimeInterval(-31 * 86_400))
        #expect(await store.list().map(\.id) == [kept.id])
        #expect(await store.listDeleted().map(\.id) == [old.id])
        // Written behind the actor's back: only a rescan could find it.
        try ParolaDocument.write(
            transcript: makeTranscript(), audioURL: nil,
            to: tmp.appendingPathComponent("stray-bundle")
        )

        let idle = await store.purgeDeletedOlderThan(days: 60, now: now)
        #expect(idle.purged == 0)
        #expect(await store.list().map(\.id) == [kept.id])

        let result = await store.purgeDeletedOlderThan(days: 30, now: now)
        #expect(result.purgedIDs == [old.id])
        #expect(await store.list().map(\.id) == [kept.id])
        #expect(await store.listDeleted().isEmpty)
    }

    @Test("a bundle another process writes reads as a change; the store's own add and purge don't")
    func folderChangeFromElsewhere() async throws {
        let (store, tmp) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(await store.folderChangedElsewhere() == false)
        let first = try await store.add(transcript: makeTranscript(), audioSource: nil)
        _ = await store.list()
        #expect(await store.folderChangedElsewhere() == false)

        let second = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.purge(first.id)
        #expect(await store.folderChangedElsewhere() == false)

        let outside = LibraryStore(libraryURL: tmp, extraIndexer: nil)
        let written = try await outside.add(transcript: makeTranscript(), audioSource: nil)
        #expect(await store.folderChangedElsewhere())

        await store.dropCaches()
        #expect(Set(await store.list().map(\.id)) == [second.id, written.id])
        #expect(await store.folderChangedElsewhere() == false)
    }

    @Test("a load cancelled before it starts throws instead of decoding")
    func cancelledLoadDoesNotDeliver() async throws {
        let (store, tmp) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        // The add left the entry cached; this load has to go to disk.
        await store.dropCaches()

        let loading = Task { () -> LoadedEntry in
            for _ in 0..<1_000 where !Task.isCancelled {
                await Task.yield()
            }
            return try await store.load(entry.id)
        }
        loading.cancel()

        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(try await store.load(entry.id).entry.id == entry.id)
    }

    @Test("an add cancelled after the write still lists and indexes the bundle")
    func cancelledAddKeepsTheBundleListed() async throws {
        let written = OSAllocatedUnfairLock(initialState: false)
        let proceed = DispatchSemaphore(value: 0)
        let (store, tmp) = try makeTempLibrary(didWriteBundle: {
            written.withLock { $0 = true }
            proceed.wait()
        })
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "kangaroo invoice")],
            language: "en",
            modelName: "tiny"
        )

        // Primes the list and index caches, which are what a skipped bookkeeping pass would strand.
        #expect(await store.list().isEmpty)
        #expect(await store.search("kangaroo").isEmpty)

        let adding = Task { try await store.add(transcript: transcript, audioSource: nil) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !written.withLock({ $0 }) {
            if ContinuousClock.now > deadline {
                Issue.record("the bundle was never written")
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        adding.cancel()
        proceed.signal()

        await #expect(throws: CancellationError.self) { _ = try await adding.value }
        let entries = await store.list()
        #expect(entries.count == 1, "a bundle on disk that no list shows is invisible until relaunch")
        #expect(await store.search("kangaroo").count == 1, "the cancelled add left the entry unindexed")
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
        let url = indexManifestURL(in: dir)
        return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func indexDirectoryURL(in libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent(".search-index", isDirectory: true)
    }

    private func indexManifestURL(in libraryURL: URL) -> URL {
        indexDirectoryURL(in: libraryURL).appendingPathComponent("manifest.json")
    }

    private func indexEntryURL(_ id: String, in libraryURL: URL) -> URL {
        indexDirectoryURL(in: libraryURL)
            .appendingPathComponent("entries", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    private func legacyIndexURL(in libraryURL: URL) -> URL {
        indexDirectoryURL(in: libraryURL).appendingPathExtension("json")
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
        defer { try? FileManager.default.removeItem(at: dir) }
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
        defer { try? FileManager.default.removeItem(at: dir) }
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
        let before = try #require(try snapshotWrittenAt(dir))

        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await relaunched.search("hi").count == 1)
        await relaunched.flush()

        #expect(try snapshotWrittenAt(dir) == before, "a rebuild would rewrite the snapshot")
    }

    @Test("an unreadable bundle does not reindex the library on every launch")
    func unreadableBundleLeavesTheIndexFresh() async throws {
        let (store, dir) = try makeTempLibrary()
        _ = try await store.add(transcript: makeTranscript(), audioSource: nil, title: "wholemarker")
        let broken = try await store.add(
            transcript: makeTranscript(), audioSource: nil, title: "brokenmarker"
        )
        await store.flush()
        try Data("not json".utf8).write(to: broken.bundleURL.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".search-index", isDirectory: true))

        let first = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await first.search("brokenmarker").count == 1, "the title stays searchable")
        await first.flush()
        let before = try #require(try snapshotWrittenAt(dir))

        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await relaunched.search("wholemarker").count == 1)
        await relaunched.flush()

        #expect(try snapshotWrittenAt(dir) == before, "a rebuild would rewrite the snapshot")
    }

    @Test("an unreadable bundle keeps its manifest notes searchable")
    func unreadableBundleKeepsItsNotesSearchable() async throws {
        let (store, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = try await store.add(
            transcript: makeTranscript(), audioSource: nil, title: "brokenmarker"
        )
        try await store.setSegmentNote("notemarker", segmentID: 0, for: broken.id)
        await store.flush()
        try Data("not json".utf8).write(to: broken.bundleURL.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".search-index", isDirectory: true))

        let degraded = LibraryStore(libraryURL: dir, extraIndexer: nil)

        #expect(await degraded.search("notemarker").count == 1)
        #expect(await degraded.search("hi").isEmpty, "the transcript itself is still unreadable")
    }

    @Test("repairing an unreadable bundle puts its transcript back in the index")
    func repairingAnUnreadableBundleReindexesIt() async throws {
        let (store, dir) = try makeTempLibrary()
        let broken = try await store.add(
            transcript: makeTranscript(), audioSource: nil, title: "brokenmarker"
        )
        await store.flush()
        let transcriptURL = broken.bundleURL.appendingPathComponent("transcript.json")
        let good = try Data(contentsOf: transcriptURL)
        try Data("not json".utf8).write(to: transcriptURL)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".search-index", isDirectory: true))

        let degraded = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await degraded.search("hi").isEmpty)
        await degraded.flush()

        try good.write(to: transcriptURL)
        let repaired = LibraryStore(libraryURL: dir, extraIndexer: nil)

        #expect(await repaired.search("hi").count == 1)
    }

    @Test("a timing-only write leaves the index fresh for the next launch")
    func timingOnlyWriteKeepsTheIndexFresh() async throws {
        let (store, dir) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        var nudged = makeTranscript()
        nudged.segments[0].start = 0.25
        try await store.updateTranscript(nudged, for: entry.id, reindex: false)
        await store.flush()
        let before = try #require(try snapshotWrittenAt(dir))

        let relaunched = LibraryStore(libraryURL: dir, extraIndexer: nil)
        #expect(await relaunched.search("hi").count == 1)
        await relaunched.flush()

        #expect(try snapshotWrittenAt(dir) == before, "a rebuild would rewrite the snapshot")
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

    @Test("segment boundaries land where the joined transcript puts each segment")
    func segmentBoundariesMatchJoinedText() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 3, text: " Buongiorno a tutti "),
                TranscriptSegment(id: 1, start: 4.5, end: 5, text: "   "),
                TranscriptSegment(id: 2, start: 9, end: 12, text: "il lancio è vicino")
            ],
            language: "it",
            modelName: "tiny"
        )
        let boundaries = LibraryStore.segmentBoundaries(for: transcript)
        let cleaned = transcript.segments.droppingBlankText()
        let text = transcript.text
        #expect(boundaries.count == cleaned.count)
        #expect(boundaries.map(\.seconds) == [0, 9])
        for (segment, boundary) in zip(cleaned, boundaries) {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = text.index(text.startIndex, offsetBy: boundary.textOffset)
            #expect(text[start...].hasPrefix(trimmed))
        }
    }

    /// The silent segment never reaches the app, so the hit after it is index 1, not 2.
    @Test("a hit past a silent segment resolves to its place in the cleaned transcript")
    func hitPastASilentSegmentResolvesToTheCleanedIndex() async throws {
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: indexDirectory) }
        let index = LibrarySearchIndex(indexDirectory: indexDirectory)
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 3, text: "Buongiorno a tutti"),
                TranscriptSegment(id: 1, start: 4.5, end: 5, text: "   "),
                TranscriptSegment(id: 2, start: 9, end: 12, text: "lancio di primavera")
            ],
            language: "it",
            modelName: "tiny"
        )
        await index.index(
            id: "e1",
            title: "Note",
            text: transcript.text,
            boundaries: LibraryStore.segmentBoundaries(for: transcript),
            createdAt: Date()
        )
        let hit = try #require(await index.search("lancio").first?.firstHit)
        #expect(hit.segmentIndex == 1)
        #expect(hit.seconds == 9)
        await index.flush()
    }

    /// A legacy bundle carries the silent rows on disk; the rebuild must index the list `load` returns.
    @Test("a rebuilt legacy bundle reports the index the loaded transcript holds")
    func rebuiltBoundariesAddressTheLoadedTranscript() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "   "),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "Buongiorno a tutti"),
                TranscriptSegment(id: 2, start: 5, end: 6, text: ""),
                TranscriptSegment(id: 3, start: 9, end: 12, text: "parliamo del lancio")
            ],
            language: "it",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        await store1.flush()

        try FileManager.default.removeItem(at: libraryURL.appendingPathComponent(".search-index", isDirectory: true))
        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let hit = try #require(await store2.search("lancio").first(where: { $0.entryID == entry.id })?.firstHit)
        let loaded = try await store2.load(entry.id).document.transcript.segments

        #expect(loaded.count == 2)
        #expect(loaded.indices.contains(hit.segmentIndex))
        #expect(loaded[hit.segmentIndex].text == "parliamo del lancio")
        #expect(hit.seconds == 9)
        await store2.flush()
    }

    @Test("a search result carries the time of its first transcript hit, rebuild included")
    func searchReportsFirstHitTime() async throws {
        let (store1, libraryURL) = try makeTempLibrary()
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 3, text: "Buongiorno a tutti"),
                TranscriptSegment(id: 1, start: 12.4, end: 20, text: "parliamo del lancio di primavera")
            ],
            language: "it",
            modelName: "tiny"
        )
        let entry = try await store1.add(transcript: transcript, audioSource: nil)
        let added = try #require(await store1.search("lancio").first(where: { $0.entryID == entry.id })?.firstHit)
        #expect(added.segmentIndex == 1)
        #expect(added.seconds == 12.4)
        await store1.flush()

        try FileManager.default.removeItem(at: libraryURL.appendingPathComponent(".search-index", isDirectory: true))
        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let rebuilt = try #require(await store2.search("lancio").first(where: { $0.entryID == entry.id })?.firstHit)
        #expect(rebuilt == added)
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

    @Test("search breaks ties on occurrences, then the newest entry, then the id, the same on every store")
    func searchTieOrderIsStable() async throws {
        let (store, url) = try makeTempLibrary()
        let sameMoment = Date(timeIntervalSinceNow: -4 * 3600)
        func add(_ text: String, createdAt: Date) async throws -> LibraryEntry {
            let entry = try await store.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                    language: "en",
                    modelName: "tiny"
                ),
                audioSource: nil
            )
            try ParolaDocument.updateManifest(at: entry.bundleURL) { $0.createdAt = createdAt }
            return entry
        }
        let twins = [
            try await add("budget", createdAt: sameMoment),
            try await add("budget", createdAt: sameMoment),
        ].sorted { $0.id < $1.id }
        let older = try await add("budget", createdAt: Date(timeIntervalSinceNow: -3 * 3600))
        let repeated = try await add("budget budget budget", createdAt: Date(timeIntervalSinceNow: -5 * 3600))
        let newer = try await add("budget", createdAt: Date(timeIntervalSinceNow: -3600))
        let twoTerms = try await add("budgeting the budget", createdAt: Date(timeIntervalSinceNow: -6 * 3600))
        await store.dropCaches()
        let expected = [twoTerms.id, repeated.id, newer.id, older.id] + twins.map(\.id)

        #expect(await store.search("budget").map(\.entryID) == expected)
        let reopened = LibraryStore(libraryURL: url, extraIndexer: nil)
        #expect(await reopened.search("budget").map(\.entryID) == expected)
    }

    @Test("only the first matches carry a snippet, and the rest fill to what a full search gives")
    func searchSnippetsForTheFirstPage() async throws {
        let (store, _) = try makeTempLibrary()
        let bodies = [
            "we looked at the budget for march and april",
            "a long preamble before anyone says budget out loud",
            "budget budget budget",
            "notes on the quarter; budgeting comes last",
        ]
        for body in bodies {
            _ = try await store.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: body)],
                    language: "en",
                    modelName: "tiny"
                ),
                audioSource: nil
            )
        }
        let full = await store.search("budget")
        #expect(full.count == 4)
        #expect(full.allSatisfy { !$0.snippet.isEmpty && !$0.highlights.isEmpty })

        let paged = await store.search("budget", snippetLimit: 2)
        #expect(paged.map(\.entryID) == full.map(\.entryID))
        #expect(Array(paged.prefix(2)) == Array(full.prefix(2)))
        #expect(paged.dropFirst(2).allSatisfy { $0.snippet.isEmpty && $0.highlights.isEmpty })
        #expect(paged.map(\.firstHit) == full.map(\.firstHit))

        let filled = await store.withSnippets(Array(paged.dropFirst(2)), query: "budget")
        #expect(filled == Array(full.dropFirst(2)))
        #expect(await store.search("budget", snippetLimit: 0).allSatisfy(\.snippet.isEmpty))
    }

    @Test("a duration set through the store is what the next listing reports")
    func setDurationSecondsRecaches() async throws {
        let (store, _) = try makeTempLibrary()
        var transcript = makeTranscript()
        transcript.durationSeconds = 2134
        let entry = try await store.add(transcript: transcript, audioSource: nil)
        #expect(await store.list().first?.durationSeconds == 2134)

        try await store.setDurationSeconds(1, for: entry.id)

        #expect(await store.list().first?.durationSeconds == 1)
        #expect(try await store.load(entry.id).entry.durationSeconds == 1)
    }

    @Test("a summary or a translation written after a duration correction keeps the corrected length")
    func storeWritesKeepTheCorrectedDuration() async throws {
        let (store, _) = try makeTempLibrary()
        var transcript = makeTranscript()
        transcript.durationSeconds = 2134
        let entry = try await store.add(transcript: transcript, audioSource: nil)
        try await store.setDurationSeconds(1, for: entry.id)

        try await store.setSummary(Summary(text: "A short take."), for: entry.id)
        #expect(await store.list().first?.durationSeconds == 1)
        #expect(try await store.load(entry.id).document.transcript.durationSeconds == 1)

        try await store.setTranslation(
            TranscriptTranslation(targetLanguage: "it", segments: [0: "ciao"], createdAt: Date(), provider: "test"),
            for: entry.id
        )
        #expect(await store.list().first?.durationSeconds == 1)
    }

    @Test("a summary set after the entry was added is searchable, and a cleared one stops matching")
    func setSummaryReindexes() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        #expect(await store.search("renewal").isEmpty)

        try await store.setSummary(Summary(text: "Renewal deadlines are slipping"), for: entry.id)
        #expect(await store.search("renewal").map(\.entryID) == [entry.id])
        #expect(try await store.load(entry.id).document.transcript.summary?.text == "Renewal deadlines are slipping")

        try await store.setSummary(nil, for: entry.id)
        #expect(await store.search("renewal").isEmpty)
        #expect(try await store.load(entry.id).document.transcript.summary == nil)
    }

    @Test("a summary set with its chapters writes both lists together, and a clear can keep the chapters")
    func setSummaryWritesTheChapterList() async throws {
        let (store, _) = try makeTempLibrary()
        var generated = makeTranscript()
        generated.chapters = [Chapter(title: "Generated", start: 0)]
        let entry = try await store.add(transcript: generated, audioSource: nil)
        let summarized = [Chapter(title: "Opening", start: 0), Chapter(title: "Wrap up", start: 1)]

        try await store.setSummary(Summary(text: "Recap", chapters: summarized), chapters: summarized, for: entry.id)
        var stored = try await store.load(entry.id).document.transcript
        #expect(stored.summary?.chapters == summarized)
        #expect(stored.chapters == summarized)

        try await store.setSummary(nil, chapters: summarized, for: entry.id)
        stored = try await store.load(entry.id).document.transcript
        #expect(stored.summary == nil)
        #expect(stored.chapters == summarized)

        try await store.setSummary(Summary(text: "Other"), for: entry.id)
        #expect(try await store.load(entry.id).document.transcript.chapters == summarized)
    }

    @Test("chapters and action items set on their own land in the entry and leave the rest alone")
    func setChaptersAndActionItems() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        try await store.setSummary(Summary(text: "Recap"), for: entry.id)
        let chapters = [Chapter(title: "Opening", start: 0)]
        let items = [ActionItem(assignee: "Ada", task: "Send the deck", dueDate: "Friday")]

        try await store.setChapters(chapters, for: entry.id)
        try await store.setActionItems(items, for: entry.id)

        var stored = try await store.load(entry.id).document.transcript
        #expect(stored.chapters == chapters)
        #expect(stored.summary?.chapters == chapters)
        #expect(stored.summary?.text == "Recap")
        #expect(stored.actionItems == items)

        try await store.setActionItems(nil, for: entry.id)
        stored = try await store.load(entry.id).document.transcript
        #expect(stored.actionItems == nil)
        #expect(stored.chapters == chapters)
    }

    @Test("a summary a save already wrote without indexing still reaches the index")
    func setSummaryIndexesWhatASaveWrote() async throws {
        let (store, _) = try makeTempLibrary()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        var saved = makeTranscript()
        saved.summary = Summary(text: "Renewal deadlines are slipping")
        try await store.updateTranscript(saved, for: entry.id, reindex: false)
        #expect(await store.search("renewal").isEmpty)

        try await store.setSummary(saved.summary, for: entry.id)

        #expect(await store.search("renewal").map(\.entryID) == [entry.id])
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

        let v2 = """
        {"version":2,"entries":{"\(entry.id)":{"title":"Old","excerpt":"kryptonite meeting notes","tokens":["kryptonite","meeting","notes"]}}}
        """
        try FileManager.default.removeItem(at: indexDirectoryURL(in: libraryURL))
        try Data(v2.utf8).write(to: legacyIndexURL(in: libraryURL))

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

        let oldFormat = """
        {"entries":{"ghost":{"id":"ghost","title":"Ghost","text":"phantom words"}},"inverted":{"phantom":["ghost"],"words":["ghost"]}}
        """
        try FileManager.default.removeItem(at: indexDirectoryURL(in: libraryURL))
        try Data(oldFormat.utf8).write(to: legacyIndexURL(in: libraryURL))

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

        let v3 = """
        {"version":3,"entries":{"\(entry.id)":{"title":"Old","excerpt":"phantom","tokens":["phantom"]}}}
        """
        try FileManager.default.removeItem(at: indexDirectoryURL(in: libraryURL))
        try Data(v3.utf8).write(to: legacyIndexURL(in: libraryURL))

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

        try FileManager.default.removeItem(at: indexDirectoryURL(in: libraryURL))

        let store2 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store2.search("kryptonite").contains(where: { $0.entryID == entry.id }))
        await store2.flush()

        let raw = try #require(
            String(data: Data(contentsOf: indexEntryURL(entry.id, in: libraryURL)), encoding: .utf8)
        )
        #expect(raw.contains("kryptonite"))

        let store3 = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store3.search("kryptonite").contains(where: { $0.entryID == entry.id }))
    }

    @Test("an empty library with no snapshot searches without error")
    func missingIndexSnapshotEmptyLibrary() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        #expect(await store.search("kryptonite").isEmpty)
        #expect(FileManager.default.fileExists(atPath: indexManifestURL(in: libraryURL).path))
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
        #expect(FileManager.default.fileExists(atPath: indexManifestURL(in: tmp).path) == false)
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

    @Test("sizeOnDisk sums the bundles and nothing else")
    func sizeOnDiskSumsBundles() async throws {
        let (store, libraryURL) = try makeTempLibrary()
        let bundle = libraryURL.appendingPathComponent("entry.parola", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 2_000).write(to: bundle.appendingPathComponent("audio.wav"))
        let indexEntries = indexDirectoryURL(in: libraryURL).appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: indexEntries, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: 400_000).write(to: indexEntries.appendingPathComponent("e1.json"))

        let bytes = try #require(await store.sizeOnDisk())
        #expect(bytes >= 2_000)
        #expect(bytes < 400_000)
    }

    @Test("sizeOnDisk reports nothing when the library cannot be listed")
    func sizeOnDiskIsNilWithoutADirectory() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-tests-\(UUID().uuidString).txt")
        try Data("not a library".utf8).write(to: file)
        let store = LibraryStore(libraryURL: file, extraIndexer: nil)
        #expect(await store.sizeOnDisk() == nil)
    }
}
