import Testing
import Foundation
import os
@testable import ParolaCore

@Suite("LibraryStore roles", .tags(.fileSystem))
struct LibraryReaderTests {
    private func makeTempLibraryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func owner(_ url: URL) -> LibraryStore {
        LibraryStore(libraryURL: url, extraIndexer: nil)
    }

    private func reader(_ url: URL) -> LibraryStore {
        LibraryStore(libraryURL: url, extraIndexer: nil, role: .reader)
    }

    private func transcript(_ text: String, duration: Double? = nil) -> Transcript {
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "tiny"
        )
        transcript.durationSeconds = duration
        return transcript
    }

    private func seedBundle(in dir: URL, named name: String, text: String) throws {
        _ = try ParolaDocument.write(transcript: transcript(text), audioURL: nil, to: dir.appendingPathComponent(name))
    }

    private func indexDirectory(in dir: URL) -> URL {
        dir.appendingPathComponent(".search-index", isDirectory: true)
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Every file under the index directory with its modification date, so a test can tell which ones a save rewrote.
    private func snapshotFiles(in dir: URL) -> [String: Date] {
        let root = indexDirectory(in: dir)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var files: [String: Date] = [:]
        for case let url as URL in walker where !url.hasDirectoryPath {
            files[url.lastPathComponent] = modified(url)
        }
        return files
    }

    @Test("a store that lists and looks up digests never loads its search index")
    func listingLeavesTheIndexAlone() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker")

        let store = owner(dir)
        #expect(await store.list().count == 1)
        #expect(await store.findEntry(digest: "abc") == nil)
        await store.flush()

        #expect(await !store.hasRequestedSearchIndex)
        #expect(snapshotFiles(in: dir).isEmpty)
    }

    @Test("warming the owner's index writes the snapshot before anything searches")
    func warmingWritesTheSnapshot() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker")

        let store = owner(dir)
        await store.warmSearchIndex()
        await store.flush()

        #expect(snapshotFiles(in: dir).keys.sorted() == ["manifest.json", "seeded.json"])
    }

    @Test("a reader searches a library with no snapshot and writes none")
    func readerWithoutSnapshotWritesNothing() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker in the minutes")

        let store = reader(dir)
        #expect(await store.search("zzyzxmarker").map(\.entryID) == ["seeded"])
        await store.flush()

        #expect(!FileManager.default.fileExists(atPath: indexDirectory(in: dir).path))
    }

    @Test("a reader catches up on a bundle the snapshot lacks without rewriting the snapshot")
    func readerCatchesUpInMemory() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        _ = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        _ = try await app.add(transcript: transcript("beta minutes"), audioSource: nil)
        await app.flush()
        let before = snapshotFiles(in: dir)
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker minutes")

        let store = reader(dir)
        #expect(await store.search("zzyzxmarker").map(\.entryID) == ["seeded"])
        #expect(await store.search("minutes").count == 3)
        await store.flush()

        #expect(snapshotFiles(in: dir) == before)
    }

    @Test("a reader's save stays out of the snapshot, and the owner's next launch indexes that entry alone")
    func ownerIndexesAReadersSave() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        let kept = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        await app.flush()
        let before = snapshotFiles(in: dir)

        let mcp = reader(dir)
        let saved = try await mcp.add(transcript: transcript("zzyzxmarker minutes"), audioSource: nil)
        await mcp.flush()
        #expect(snapshotFiles(in: dir) == before)
        #expect(await mcp.search("zzyzxmarker").map(\.entryID) == [saved.id])

        let relaunched = owner(dir)
        #expect(await relaunched.search("zzyzxmarker").map(\.entryID) == [saved.id])
        await relaunched.flush()
        let after = snapshotFiles(in: dir)
        #expect(after["\(saved.id).json"] != nil)
        #expect(after["\(kept.id).json"] == before["\(kept.id).json"], "an entry that did not change is not written again")
    }

    @Test("a bundle rewritten behind the owner is the only one read and written again")
    func ownerReindexesOnlyTheRewrittenBundle() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedBundle(in: dir, named: "first", text: "alpha minutes")
        try seedBundle(in: dir, named: "second", text: "zzyzxmarker minutes")
        let app = owner(dir)
        await app.warmSearchIndex()
        await app.flush()
        let before = snapshotFiles(in: dir)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("second.parola"))
        try seedBundle(in: dir, named: "second", text: "qqxwmarker minutes")
        let relaunched = owner(dir)
        #expect(await relaunched.search("zzyzxmarker").isEmpty)
        #expect(await relaunched.search("qqxwmarker").map(\.entryID) == ["second"])
        await relaunched.flush()

        let after = snapshotFiles(in: dir)
        #expect(after["first.json"] == before["first.json"])
        #expect(after["second.json"] != before["second.json"])
    }

    @Test("after a rescan the owner indexes what a reader saved while it ran")
    func ownerCatchesUpAfterARescan() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        _ = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        await app.flush()

        let saved = try await reader(dir).add(transcript: transcript("zzyzxmarker minutes"), audioSource: nil)
        #expect(await app.search("zzyzxmarker").isEmpty, "nothing told the app yet")
        #expect(await app.folderChangedElsewhere())
        await app.dropCaches()

        #expect(await app.search("zzyzxmarker").map(\.entryID) == [saved.id])
        await app.flush()
        #expect(snapshotFiles(in: dir)["\(saved.id).json"] != nil)
    }

    @Test("a reader's own save is not a change made elsewhere, and a quiet library is not either")
    func readerOwnSaveIsNotAChange() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        _ = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        await app.flush()
        let store = reader(dir)
        await store.reloadIfChangedElsewhere()
        _ = await store.list()
        #expect(await !store.reloadIfChangedElsewhere())

        _ = try await store.add(transcript: transcript("zzyzxmarker minutes"), audioSource: nil)
        #expect(await !store.reloadIfChangedElsewhere())

        _ = try await app.add(transcript: transcript("beta minutes"), audioSource: nil)
        #expect(await store.reloadIfChangedElsewhere())
        #expect(await store.list().count == 3)
    }

    @Test("an owner's manifest-only edit reaches a reader's next call and is not a change to the owner")
    func manifestEditReachesTheReader() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        let entry = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        _ = await app.list()
        let store = reader(dir)
        await store.reloadIfChangedElsewhere()
        #expect(await store.list().first?.pinned == false)

        try await app.setPinned(true, for: entry.id)

        #expect(await store.reloadIfChangedElsewhere())
        #expect(await store.list().first?.pinned == true)
        #expect(await !app.folderChangedElsewhere())

        try await app.markOpened(id: entry.id)
        #expect(await !store.reloadIfChangedElsewhere(), "an open changes nothing a reader shows")
    }

    @Test("searches racing a reader's index swap answer from the index that caught up")
    func searchesRacingASwapSeeTheCatchUp() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        _ = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        await app.flush()
        let gate = CatchUpGate()
        let store = LibraryStore(
            storeAt: dir, extraIndexer: nil,
            seams: LibraryStore.TestSeams(willCatchUpSearchIndex: { await gate.pass() }),
            role: .reader
        )
        await store.reloadIfChangedElsewhere()
        #expect(await store.search("alpha").count == 1)
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker minutes")
        await store.dropCaches()
        await gate.arm()

        let first = Task { await store.search("zzyzxmarker").map(\.entryID) }
        await gate.waitUntilHeld()
        // A snapshot the reader can't refresh in place makes it swap in a fresh index mid catch-up.
        try Data("not json".utf8).write(to: indexDirectory(in: dir).appendingPathComponent("manifest.json"))
        #expect(await store.reloadIfChangedElsewhere())
        let second = Task { await store.search("zzyzxmarker").map(\.entryID) }
        await gate.release()

        #expect(await first.value == ["seeded"])
        #expect(await second.value == ["seeded"])
        #expect(await store.search("minutes").count == 2)
    }

    @Test("a search that loses the race eight times still reads a caught-up index")
    func searchLosingEveryRoundStillCatchesUp() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = owner(dir)
        _ = try await app.add(transcript: transcript("alpha minutes"), audioSource: nil)
        await app.flush()
        let box = OSAllocatedUnfairLock<(store: LibraryStore?, swaps: Int)>(initialState: (nil, 0))
        let store = LibraryStore(
            storeAt: dir, extraIndexer: nil,
            seams: LibraryStore.TestSeams(willCatchUpSearchIndex: {
                let target = box.withLock { state -> LibraryStore? in
                    guard state.swaps < 8, let store = state.store else { return nil }
                    state.swaps += 1
                    return store
                }
                await target?.replaceSearchIndex()
            }),
            role: .reader
        )
        #expect(await store.search("alpha").count == 1)
        try seedBundle(in: dir, named: "seeded", text: "zzyzxmarker minutes")
        await store.dropCaches()
        box.withLock { $0.store = store }

        #expect(await store.search("zzyzxmarker").map(\.entryID) == ["seeded"])
        #expect(box.withLock { $0.swaps } == 8)
    }

    @Test("a reader leaves each bundle's manifest as it found it")
    func readerWritesNoManifest() async throws {
        let dir = try makeTempLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("clip.wav")
        try Data("RIFFfakeaudio".utf8).write(to: audio)
        let bundle = try ParolaDocument.write(
            transcript: transcript("hello", duration: 12), audioURL: audio, to: dir.appendingPathComponent("seeded")
        )
        try ParolaDocument.updateManifest(at: bundle) { manifest in
            manifest.durationSeconds = nil
            manifest.sourceDigest = nil
        }
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)

        let store = reader(dir)
        _ = try await store.load("seeded")
        let report = await store.verify()

        #expect(report.healthy.map(\.id) == ["seeded"])
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
    }
}

/// Holds the next catch-up after `arm()` until `release()`, so a test can act while it is parked.
private actor CatchUpGate {
    private var armed = false
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        armed = false
        held = true
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters = []
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
