import Foundation
import Testing
import os
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

    @Test("a file added while no store was running arrives when the next one starts; older files don't")
    func relaunchPicksUpFilesAddedWhileQuit() async throws {
        let rig = try makeRig("relaunch")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))

        let arrivals = Arrivals()
        let first = makeStore(rig, arrivals: arrivals)
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }
        await first.stopWatching()

        try writeSettled(rig.folder.appendingPathComponent("while-quit.wav"))
        let second = makeStore(rig, arrivals: arrivals)
        await pollUntil("while-quit.wav to arrive") { arrivals.names.contains("while-quit.wav") }
        await second.stopWatching()

        #expect(arrivals.names == ["while-quit.wav"])
    }

    @Test("removing a folder deletes its baseline")
    func removingAFolderDeletesItsBaseline() async throws {
        let rig = try makeRig("remove")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let store = makeStore(rig, arrivals: Arrivals())
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }
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
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }

        let settling = rig.folder.appendingPathComponent("settling.m4a")
        try Data(count: 4096).write(to: settling)
        try await Task.sleep(for: .milliseconds(200))
        store.reloadFromDefaults()

        await pollUntil("settling.m4a to arrive") { arrivals.names == ["settling.m4a"] }
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
        await pollUntil("the folder to follow its rename to Recordings") { store.folders.first?.displayName == "Recordings" }
        #expect(!store.isUnavailable(rig.folderID))
        let saved = try JSONDecoder().decode([WatchedFolder].self, from: #require(rig.defaults.data(forKey: "watchedFolders")))
        #expect(saved.map(\.displayName) == ["Recordings"])

        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }
        try writeSettled(renamed.appendingPathComponent("new.m4a"))
        await pollUntil("new.m4a to arrive") { arrivals.names == ["new.m4a"] }
        await store.stopWatching()
    }

    @Test("renaming a watched folder moves the watch with it, and nothing already there arrives again")
    func renamedFolderKeepsItsWatch() async throws {
        let rig = try makeRig("rename")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folder.appendingPathComponent("old.m4a"))

        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }

        let renamed = rig.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.moveItem(at: rig.folder, to: renamed)
        await pollUntil("the folder to follow its rename to Archive") { store.folders.first?.displayName == "Archive" }
        try writeSettled(renamed.appendingPathComponent("after-rename.wav"))

        await pollUntil("after-rename.wav to arrive") { arrivals.names.contains("after-rename.wav") }
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
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }

        try FileManager.default.removeItem(at: rig.folder)
        await pollUntil("the deleted folder to read as unavailable") { store.isUnavailable(rig.folderID) }

        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        try writeSettled(rig.folder.appendingPathComponent("back.m4a"))
        store.retryUnavailableFolders()

        await pollUntil("back.m4a to arrive") { arrivals.names == ["back.m4a"] }
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
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }
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
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        let parkedWatcher = store.watcher(for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        await pollUntil("the re-add to replace the parked watcher") {
            store.watcher(for: rig.folderID).map { $0 !== parkedWatcher } ?? false
        }
        parked.resume()

        try writeSettled(rig.folder.appendingPathComponent("new.wav"))
        await pollUntil("new.wav to arrive") { arrivals.names.contains("new.wav") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(arrivals.names == ["new.wav"])
        await store.stopWatching()
    }

    @Test("a settings reload that leaves the watched folders alone restarts no watcher")
    func unrelatedReloadKeepsWatchers() async throws {
        let rig = try makeRig("unrelated-reload")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let store = makeStore(rig, arrivals: Arrivals())
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        let before = store.watcher(for: rig.folderID)
        rig.defaults.set(true, forKey: "someOtherSetting")
        store.reloadFromDefaults()

        #expect(store.watcher(for: rig.folderID) === before)
        await store.stopWatching()
    }

    @Test("an ejected volume parks its folder until it mounts again")
    func ejectedVolumeWaitsForAMount() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-watched-volume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let image = DiskImage(image: scratch.appendingPathComponent("card.dmg"), mountPoint: scratch.appendingPathComponent("Card"))
        try await image.create()
        do {
            try await image.attach()
            try await ejectAndMountAgain(image)
        } catch {
            await image.detach()
            throw error
        }
        await image.detach()
    }

    private func ejectAndMountAgain(_ image: DiskImage) async throws {
        let folder = image.mountPoint.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSettled(folder.appendingPathComponent("old.m4a"))

        let rig = try makeRig("volume", folder: folder)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        let store = makeStore(rig, arrivals: arrivals)
        do {
            await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }

            await image.detach()
            await pollUntil("the folder to read as unavailable once its volume is gone") { store.isUnavailable(rig.folderID) }
            store.retryUnavailableFolders()
            try await Task.sleep(for: .milliseconds(300))
            #expect(store.isUnavailable(rig.folderID), "a retry with the volume away leaves the folder unavailable")

            try await image.attach()
            try writeSettled(folder.appendingPathComponent("new.wav"))
            store.retryUnavailableFolders()
            await pollUntil("new.wav to arrive") { arrivals.names.contains("new.wav") }
            #expect(arrivals.names == ["new.wav"])
            #expect(!store.isUnavailable(rig.folderID))
        } catch {
            await store.stopWatching()
            throw error
        }
        await store.stopWatching()
    }

    @Test("two quick re-adds keep what the watcher knew, so a file that already arrived doesn't arrive again")
    func quickReplacementsKeepTheCarriedBaseline() async throws {
        let rig = try makeRig("double-adopt")
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let first = makeStore(rig, arrivals: Arrivals())
        await pollUntil("the first baseline save") { FileManager.default.fileExists(atPath: rig.baselineURL.path) }
        await first.stopWatching()

        let arrivals = Arrivals()
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(60),
            baselineMaxWait: .seconds(60)
        ) { url in
            arrivals.urls.append(url)
        }
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        try writeSettled(rig.folder.appendingPathComponent("arrived.wav"))
        await pollUntil("arrived.wav to arrive") { arrivals.names == ["arrived.wav"] }

        let before = store.watcher(for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        store.adopt(rig.folder, for: rig.folderID)
        await pollUntil("a new watcher to replace the old one") {
            store.watcher(for: rig.folderID).map { $0 !== before } ?? false
        }
        try writeSettled(rig.folder.appendingPathComponent("later.wav"))
        await pollUntil("later.wav to arrive") { arrivals.names.contains("later.wav") }
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
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }

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
            baselineWriteDelay: .seconds(60),
            baselineMaxWait: .seconds(60)
        ) { url in
            arrivals.urls.append(url)
        }
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        try writeSettled(rig.folder.appendingPathComponent("arrived.wav"))
        await pollUntil("arrived.wav to arrive") { arrivals.names == ["arrived.wav"] }
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
            baselineWriteDelay: .seconds(60),
            baselineMaxWait: .seconds(60)
        ) { _ in }
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        let before = store.watcher(for: rig.folderID)

        store.adopt(rig.folder, for: rig.folderID)
        let bookmark = try elsewhere.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let moved = WatchedFolder(id: rig.folderID, bookmark: bookmark, displayPath: elsewhere.path)
        rig.defaults.set(try JSONEncoder().encode([moved]), forKey: "watchedFolders")
        store.reloadFromDefaults()

        await pollUntil("a new watcher to replace the old one") {
            store.watcher(for: rig.folderID).map { $0 !== before } ?? false
        }
        try await Task.sleep(for: .milliseconds(100))
        await WatchedFolderBaselines(directory: rig.baselineDirectory).settle()
        #expect(!FileManager.default.fileExists(atPath: rig.baselineURL.path))
        await store.stopWatching()
    }

    @Test("a change that lands while an overdue save is already under way is saved by one more pass")
    func changeDuringADueSaveIsSavedAgain() async throws {
        let rig = try makeRig("rewrite")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let store = WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .seconds(1),
            baselineMaxWait: .zero
        ) { _ in }
        await pollUntil("the first baseline save") { store.baselineSaves >= 1 }
        let before = store.baselineSaves

        store.scheduleBaselineWrite(for: rig.folderID)
        store.scheduleBaselineWrite(for: rig.folderID)
        await pollUntil("the overdue save and its second pass") { store.baselineSaves == before + 2 }
        await store.stopWatching()
    }

    @Test("the quit flush returns only after saves already queued have landed")
    func quitFlushWaitsForQueuedSaves() async throws {
        let rig = try makeRig("flush-barrier")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let store = makeStore(rig, arrivals: Arrivals())
        await pollUntil("the folder's watcher to start") { store.watcher(for: rig.folderID) != nil }
        await store.stopWatching()

        let other = UUID()
        let entries: [[String: Any]] = (0..<200_000).map {
            ["path": "recording \($0).m4a", "inode": $0, "size": 1, "modified": 0]
        }
        let json = try JSONSerialization.data(withJSONObject: ["entries": entries])
        let large = try JSONDecoder().decode(FolderWatcher.Baseline.self, from: json)
        let baselines = WatchedFolderBaselines(directory: rig.baselineDirectory)
        baselines.write(large, for: other)
        await store.pendingBaselineFlush()()

        let saved = try JSONDecoder().decode(FolderWatcher.Baseline.self, from: Data(contentsOf: baselines.fileURL(for: other)))
        #expect(saved.entries.count == 200_000)
    }
}

@MainActor
private struct DiskImage {
    let image: URL
    let mountPoint: URL

    func create() async throws {
        try await run(["create", "-size", "4m", "-fs", "HFS+", "-volname", "ParolaTest", image.path])
    }

    func attach() async throws {
        try await run(["attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse"])
    }

    /// Runs even when the test was cancelled, so a failed or cancelled test never leaves the image mounted.
    func detach() async {
        await Task { try? await run(["detach", mountPoint.path, "-force"]) }.value
    }

    private struct Failed: Error {
        let status: Int32
    }

    private func run(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exited, exit) = AsyncStream<Void>.makeStream()
        let hasExited = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { _ in
            hasExited.withLock { $0 = true }
            exit.finish()
        }
        try process.run()
        let exitedInTime = await awaitGuarded("hdiutil \(arguments[0])", timeout: .seconds(60)) {
            for await _ in exited {}
            return true
        } ?? false
        guard exitedInTime else {
            process.terminate()
            // A task of its own, so even a cancelled caller waits for hdiutil to go before its cleanup detaches.
            _ = await Task {
                await pollUntil("hdiutil \(arguments[0]) to exit after SIGTERM", timeout: .seconds(5)) {
                    hasExited.withLock { $0 }
                }
            }.value
            throw Failed(status: -1)
        }
        guard process.terminationStatus == 0 else { throw Failed(status: process.terminationStatus) }
    }
}
