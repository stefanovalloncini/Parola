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

    private func makeRig(_ label: String, folder watched: URL? = nil) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-watched-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        let folder = watched ?? root.appendingPathComponent("Inbox", isDirectory: true)
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

    @Test("an ejected volume parks its folder until it mounts again, and a retry doesn't mount it")
    func ejectedVolumeWaitsForAMount() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-watched-volume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let image = DiskImage(image: scratch.appendingPathComponent("card.dmg"), mountPoint: scratch.appendingPathComponent("Card"))
        try image.create()
        try image.attach()
        defer {
            image.detach()
            try? FileManager.default.removeItem(at: scratch)
        }
        let folder = image.mountPoint.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSettled(folder.appendingPathComponent("old.m4a"))

        let rig = try makeRig("volume", folder: folder)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })

        image.detach()
        #expect(await waitUntil { store.isUnavailable(rig.folderID) })
        store.retryUnavailableFolders()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.isUnavailable(rig.folderID))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "a retry must not mount the volume")

        try image.attach()
        try writeSettled(folder.appendingPathComponent("new.wav"))
        store.retryUnavailableFolders()
        #expect(await waitUntil { arrivals.names.contains("new.wav") })
        #expect(arrivals.names == ["new.wav"])
        #expect(!store.isUnavailable(rig.folderID))
        await store.stopWatching()
    }

    @Test("two quick re-adds keep what the watcher knew, so a file that already arrived doesn't arrive again")
    func quickReplacementsKeepTheCarriedBaseline() async throws {
        let rig = try makeRig("double-adopt")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let first = makeStore(rig, arrivals: Arrivals())
        #expect(await waitUntil { FileManager.default.fileExists(atPath: rig.baselineURL.path) })
        await first.stopWatching()

        let arrivals = Arrivals()
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(60)
        ) { url in
            arrivals.urls.append(url)
        }
        #expect(await waitUntil { store.watcher(for: rig.folderID) != nil })
        try writeSettled(rig.folder.appendingPathComponent("arrived.wav"))
        #expect(await waitUntil { arrivals.names == ["arrived.wav"] })

        let before = store.watcher(for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        #expect(await waitUntil { store.watcher(for: rig.folderID).map { $0 !== before } ?? false })
        try writeSettled(rig.folder.appendingPathComponent("later.wav"))
        #expect(await waitUntil { arrivals.names.contains("later.wav") })
        try await Task.sleep(for: .milliseconds(200))
        #expect(arrivals.names == ["arrived.wav", "later.wav"])
        await store.stopWatching()
    }

    @Test("a steady stream of changes still saves the baseline once the max wait is up")
    func baselineWriteHasAMaxWait() async throws {
        let rig = try makeRig("max-wait")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(1),
            baselineMaxWait: .milliseconds(200)
        ) { _ in }
        #expect(await waitUntil { store.watcher(for: rig.folderID) != nil })

        var savedDuringStream = false
        for _ in 0..<20 {
            store.scheduleBaselineWrite(for: rig.folderID)
            try await Task.sleep(for: .milliseconds(50))
            await WatchedFolderBaselines(directory: rig.baselineDirectory).settle()
            if FileManager.default.fileExists(atPath: rig.baselineURL.path) { savedDuringStream = true }
        }
        #expect(savedDuringStream)
        await store.stopWatching()
    }

    @Test("quitting saves a baseline that was still waiting for its debounce")
    func quitFlushesPendingBaselines() async throws {
        let rig = try makeRig("flush")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(60)
        ) { url in
            arrivals.urls.append(url)
        }
        #expect(await waitUntil { store.watcher(for: rig.folderID) != nil })
        try writeSettled(rig.folder.appendingPathComponent("arrived.wav"))
        #expect(await waitUntil { arrivals.names == ["arrived.wav"] })
        #expect(!FileManager.default.fileExists(atPath: rig.baselineURL.path))

        await store.pendingBaselineFlush()()
        let saved = try JSONDecoder().decode(FolderWatcher.Baseline.self, from: Data(contentsOf: rig.baselineURL))
        #expect(saved.entries.map(\.path) == ["arrived.wav"])
        #expect(saved.entries.first?.emittedAt != nil)
        await store.stopWatching()
    }

    @Test("a start that gives way to a reload pointing the folder elsewhere doesn't save the old folder's baseline")
    func bailingStartKeepsOutOfAMovedFolder() async throws {
        let rig = try makeRig("bail")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))
        let elsewhere = rig.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(60)
        ) { _ in }
        #expect(await waitUntil { store.watcher(for: rig.folderID) != nil })
        let before = store.watcher(for: rig.folderID)

        store.adopt(rig.folder, for: rig.folderID)
        let bookmark = try elsewhere.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let moved = WatchedFolder(id: rig.folderID, bookmark: bookmark, displayPath: elsewhere.path)
        rig.defaults.set(try JSONEncoder().encode([moved]), forKey: "watchedFolders")
        store.reloadFromDefaults()

        #expect(await waitUntil { store.watcher(for: rig.folderID).map { $0 !== before } ?? false })
        try await Task.sleep(for: .milliseconds(100))
        await WatchedFolderBaselines(directory: rig.baselineDirectory).settle()
        #expect(!FileManager.default.fileExists(atPath: rig.baselineURL.path))
        await store.stopWatching()
    }
}

private struct DiskImage {
    let image: URL
    let mountPoint: URL

    func create() throws {
        try run(["create", "-size", "4m", "-fs", "HFS+", "-volname", "ParolaTest", image.path])
    }

    func attach() throws {
        try run(["attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse"])
    }

    func detach() {
        try? run(["detach", mountPoint.path, "-force"])
    }

    private struct Failed: Error {
        let status: Int32
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(status: process.terminationStatus) }
    }
}
