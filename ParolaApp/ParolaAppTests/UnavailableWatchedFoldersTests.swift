import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Unavailable watched folders outside Settings", .serialized)
struct UnavailableWatchedFoldersTests {

    @Test("a folder gone at launch is listed for the sidebar until it is located again")
    func missingFolderIsListedUntilLocated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-unavailable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let bookmark = try inbox.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let watched = WatchedFolder(bookmark: bookmark, displayPath: inbox.path)
        let defaults = temporaryDefaults()
        defaults.set(try JSONEncoder().encode([watched]), forKey: "watchedFolders")
        try FileManager.default.removeItem(at: inbox)

        let store = WatchedFoldersStore(
            defaults: defaults,
            baselineDirectory: root.appendingPathComponent("Baselines", isDirectory: true),
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50))
        ) { _ in }

        let mapWait = await waitUntil { store.unavailableFolders.map(\.id) == [watched.id] }
        #expect(mapWait)

        let moved = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        store.adopt(moved, for: watched.id)

        let isEmptyWait = await waitUntil { store.unavailableFolders.isEmpty && store.watcher(for: watched.id) != nil }
        #expect(isEmptyWait)
        #expect(store.folders.map(\.displayPath) == [moved.path])
        await store.stopWatching()
    }

    @Test("a file a watcher handed over is traced back to its folder, and a folder's watch starting says so")
    func arrivalsKnowTheirFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-folder-of-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let bookmark = try inbox.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let watched = WatchedFolder(bookmark: bookmark, displayPath: inbox.path)
        let defaults = temporaryDefaults()
        defaults.set(try JSONEncoder().encode([watched]), forKey: "watchedFolders")
        let store = WatchedFoldersStore(
            defaults: defaults,
            baselineDirectory: root.appendingPathComponent("Baselines", isDirectory: true),
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50))
        ) { _ in }
        var starts = 0
        store.onFolderWatching = { starts += 1 }

        let startsWait = await waitUntil { starts == 1 }
        #expect(startsWait)
        let real = URL(fileURLWithPath: inbox.resolvingSymlinksInPath().path)
        #expect(store.folder(containing: real.appendingPathComponent("Sub/memo.m4a"))?.id == watched.id)
        #expect(store.folder(containing: inbox.appendingPathComponent("memo.m4a"))?.id == watched.id)
        #expect(store.folder(containing: root.appendingPathComponent("elsewhere.m4a")) == nil)
        await store.stopWatching()
    }

    @Test("a launch that doesn't watch folders never builds the store for the sidebar")
    func sidebarLeavesTheStoreAloneWhenNotWatching() {
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("unavailable")
        )
        #expect(model.watchedFoldersIfWatching == nil)
    }
}

extension UnavailableWatchedFoldersTests {
    @Test("a missing file is gone only when its folder answered, is watched and isn't unavailable")
    func verdictTable() {
        typealias Arrival = WatchedArrival
        #expect(Arrival.verdict(probed: .gone, folderIsUnavailable: false, folderVouches: true) == .gone)
        #expect(Arrival.verdict(probed: .gone, folderIsUnavailable: false, folderVouches: false) == .unreachable)
        #expect(Arrival.verdict(probed: .present, folderIsUnavailable: false, folderVouches: false) == .present)
        #expect(Arrival.verdict(probed: nil, folderIsUnavailable: false, folderVouches: true) == .unreachable)
        #expect(Arrival.verdict(probed: .present, folderIsUnavailable: true, folderVouches: true) == .unreachable)
    }

    @Test("only a started watch vouches for a folder; a file whose folder came back mid-check is checked again")
    func missingFileWaitsForTheWatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-vouch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let share = root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let bookmark = try share.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let watched = WatchedFolder(bookmark: bookmark, displayPath: share.path)
        let defaults = temporaryDefaults()
        defaults.set(try JSONEncoder().encode([watched]), forKey: "watchedFolders")
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("vouch"),
            defaultsOverride: defaults,
            sideEffects: [.watchedFolders],
            filePicker: TestFilePicker(),
            clock: ContinuousClock()
        ))
        let missing = WatchedArrival(
            url: share.appendingPathComponent("never-mounted.wav"), folderID: watched.id, folderPath: share.path
        )
        #expect(!model.watchedFolderVouches(for: missing), "the watch hasn't started yet")
        #expect(model.watchedFolderVouches(for: WatchedArrival(url: missing.url)))

        let answer = DispatchSemaphore(value: 0)
        model.watchedFileReach = { _, _ in
            answer.wait()
            return .gone
        }
        model.watchedArrivals = [missing]
        model.pumpWatchedLane()
        let watcherWait = await waitUntil { model.watchedFolders.watcher(for: watched.id) != nil }
        #expect(watcherWait)
        #expect(model.watchedFolderVouches(for: missing))
        answer.signal()
        answer.signal()

        let isEmptyWait = await waitUntil { model.watchedArrivals.isEmpty }
        #expect(isEmptyWait)
        #expect(model.unreachableArrivalIDs.isEmpty)
        await model.watchedFolders.stopWatching()
    }
}
