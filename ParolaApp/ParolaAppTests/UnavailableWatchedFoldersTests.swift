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

        #expect(await waitUntil { store.unavailableFolders.map(\.id) == [watched.id] })

        let moved = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        store.adopt(moved, for: watched.id)

        #expect(await waitUntil { store.unavailableFolders.isEmpty && store.watcher(for: watched.id) != nil })
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

        #expect(await waitUntil { starts == 1 })
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
