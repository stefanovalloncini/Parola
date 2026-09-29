import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Watched folders store watching real folders", .serialized)
struct WatchedFoldersStoreWatchingTests {

    private final class Arrivals {
        var urls: [URL] = []
        var names: [String] { urls.map(\.lastPathComponent) }
    }

    private struct Rig {
        let root: URL
        let folder: URL
        let baselineDirectory: URL
        let defaults: UserDefaults
        let folderID: UUID

        var baselineURL: URL { baselineDirectory.appendingPathComponent("\(folderID.uuidString).json") }
    }

    private func makeRig(_ label: String) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-watched-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = temporaryDefaults()
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let watched = WatchedFolder(bookmark: bookmark, displayPath: folder.path)
        defaults.set(try JSONEncoder().encode([watched]), forKey: "watchedFolders")
        return Rig(
            root: root,
            folder: folder,
            baselineDirectory: root.appendingPathComponent("Baselines", isDirectory: true),
            defaults: defaults,
            folderID: watched.id
        )
    }

    private func makeStore(_ rig: Rig, arrivals: Arrivals) -> WatchedFoldersStore {
        WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .milliseconds(10)
        ) { url in
            arrivals.urls.append(url)
        }
    }

    private func writeSettled(_ url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        try Data(count: 2048).write(to: staging)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: url)
    }

    private func waitUntil(timeoutMs: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    @Test("a file added while no store was running arrives when the next one starts; older files don't")
    func relaunchPicksUpFilesAddedWhileQuit() async throws {
        let rig = try makeRig("relaunch")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))

        let arrivals = Arrivals()
        let first = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })
        await first.stopWatching()

        try writeSettled(rig.folder.appendingPathComponent("while-quit.wav"))
        let second = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { arrivals.names.contains("while-quit.wav") })
        await second.stopWatching()

        #expect(arrivals.names == ["while-quit.wav"])
    }

    @Test("removing a folder deletes its baseline")
    func removingAFolderDeletesItsBaseline() async throws {
        let rig = try makeRig("remove")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let store = makeStore(rig, arrivals: Arrivals())
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })
        store.removeFolder(rig.folderID)
        await WatchedFolderBaselines(directory: rig.baselineDirectory).settle()

        #expect(!FileManager.default.fileExists(atPath: rig.baselineURL.path))
        #expect(store.folders.isEmpty)
    }

    @Test("a settings reload keeps a file that was still settling")
    func reloadKeepsASettlingFile() async throws {
        let rig = try makeRig("reload")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let arrivals = Arrivals()
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .seconds(1)),
            baselineWriteDelay: .milliseconds(10)
        ) { url in
            arrivals.urls.append(url)
        }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })

        let settling = rig.folder.appendingPathComponent("settling.m4a")
        try Data(count: 4096).write(to: settling)
        try await Task.sleep(for: .milliseconds(200))
        store.reloadFromDefaults()

        #expect(await waitUntil { arrivals.names == ["settling.m4a"] })
        await store.stopWatching()
    }

    @Test("a stale bookmark is refreshed and the renamed folder is watched under its new name")
    func staleBookmarkIsRefreshed() async throws {
        let rig = try makeRig("stale")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let renamed = rig.root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.moveItem(at: rig.folder, to: renamed)

        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { store.folders.first?.displayName == "Recordings" })
        #expect(!store.isUnavailable(rig.folderID))
        let saved = try JSONDecoder().decode([WatchedFolder].self, from: #require(rig.defaults.data(forKey: "watchedFolders")))
        #expect(saved.map(\.displayName) == ["Recordings"])

        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })
        try writeSettled(renamed.appendingPathComponent("new.m4a"))
        #expect(await waitUntil { arrivals.names == ["new.m4a"] })
        await store.stopWatching()
    }

    @Test("renaming a watched folder moves the watch with it, and nothing already there arrives again")
    func renamedFolderKeepsItsWatch() async throws {
        let rig = try makeRig("rename")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))

        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })

        let renamed = rig.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.moveItem(at: rig.folder, to: renamed)
        #expect(await waitUntil { store.folders.first?.displayName == "Archive" })
        try writeSettled(renamed.appendingPathComponent("after-rename.wav"))

        #expect(await waitUntil { arrivals.names.contains("after-rename.wav") })
        #expect(arrivals.names == ["after-rename.wav"])
        #expect(!store.isUnavailable(rig.folderID))
        await store.stopWatching()
    }

    @Test("a watched folder deleted and made again is watched again after a retry")
    func recreatedFolderIsWatchedAgain() async throws {
        let rig = try makeRig("recreate")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })

        try FileManager.default.removeItem(at: rig.folder)
        #expect(await waitUntil { store.isUnavailable(rig.folderID) })

        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        try writeSettled(rig.folder.appendingPathComponent("back.m4a"))
        store.retryUnavailableFolders()

        #expect(await waitUntil { arrivals.names == ["back.m4a"] })
        #expect(!store.isUnavailable(rig.folderID))
        await store.stopWatching()
    }

    @Test("re-adding a folder while its watcher is on its first scan brings back nothing already there")
    func replacingAWatcherMidFirstScanFloodsNothing() async throws {
        let rig = try makeRig("midscan")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))

        let arrivals = Arrivals()
        let first = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })
        await first.stopWatching()

        let parked = DispatchQueue(label: "parola.test.parked-scan")
        parked.suspend()
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50), scanQueue: parked),
            baselineWriteDelay: .milliseconds(10)
        ) { url in
            arrivals.urls.append(url)
        }
        let watching = await waitUntil { store.watcher(for: rig.folderID) != nil }
        let parkedWatcher = store.watcher(for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        let replaced = await waitUntil { store.watcher(for: rig.folderID).map { $0 !== parkedWatcher } ?? false }
        parked.resume()
        #expect(watching)
        #expect(replaced)

        try writeSettled(rig.folder.appendingPathComponent("new.wav"))
        #expect(await waitUntil { arrivals.names.contains("new.wav") })
        try await Task.sleep(for: .milliseconds(200))
        #expect(arrivals.names == ["new.wav"])
        await store.stopWatching()
    }

    @Test("a settings reload that leaves the watched folders alone restarts no watcher")
    func unrelatedReloadKeepsWatchers() async throws {
        let rig = try makeRig("unrelated-reload")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let store = makeStore(rig, arrivals: Arrivals())
        #expect(await waitUntil { store.watcher(for: rig.folderID) != nil })
        let before = store.watcher(for: rig.folderID)
        rig.defaults.set(true, forKey: "someOtherSetting")
        store.reloadFromDefaults()

        #expect(store.watcher(for: rig.folderID) === before)
        await store.stopWatching()
    }
}
