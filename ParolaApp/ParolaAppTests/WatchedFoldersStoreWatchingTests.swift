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
}
