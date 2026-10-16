import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Watched folders store options", .serialized)
struct WatchedFoldersStoreOptionsTests {

    private final class Arrivals {
        var urls: [URL] = []
        var names: [String] { urls.map(\.lastPathComponent) }
    }

    private struct Rig {
        let root: URL
        let folders: [URL]
        let baselineDirectory: URL
        let defaults: UserDefaults
        let ids: [UUID]
    }

    private func makeRig(_ label: String, folderCount: Int = 1, options: [WatchedFolderOptions] = []) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-folder-options-\(label)-\(UUID().uuidString)", isDirectory: true)
        var folders: [URL] = []
        var watched: [WatchedFolder] = []
        for index in 0..<folderCount {
            let folder = root.appendingPathComponent("Inbox\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            watched.append(WatchedFolder(
                bookmark: bookmark, displayPath: folder.path, options: options.indices.contains(index) ? options[index] : .default
            ))
            folders.append(folder)
        }
        let defaults = temporaryDefaults()
        defaults.set(try JSONEncoder().encode(watched), forKey: "watchedFolders")
        return Rig(
            root: root, folders: folders, baselineDirectory: root.appendingPathComponent("Baselines", isDirectory: true),
            defaults: defaults, ids: watched.map(\.id)
        )
    }

    private func makeStore(_ rig: Rig, arrivals: Arrivals, picker: any FilePicker = TestFilePicker()) -> WatchedFoldersStore {
        WatchedFoldersStore(
            defaults: rig.defaults,
            baselineDirectory: rig.baselineDirectory,
            watcherOptions: FolderWatcher.Options(settledInterval: .milliseconds(50)),
            baselineWriteDelay: .milliseconds(10),
            picker: picker
        ) { url in
            arrivals.urls.append(url)
        }
    }

    private func writeSettled(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        try Data(count: 2048).write(to: staging)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: url)
    }

    private func depthOptions(depth subfolders: Bool = true) -> WatchedFolderOptions {
        var options = WatchedFolderOptions()
        options.includesSubfolders = subfolders
        return options
    }

    @Test("a folder watched for itself alone reports nothing from its subfolders")
    func thisFolderOnly() async throws {
        let rig = try makeRig("flat", options: [depthOptions(depth: false)])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        var starts = 0
        let store = makeStore(rig, arrivals: arrivals)
        store.onFolderWatching = { starts += 1 }
        await waitUntil { starts == 1 }

        try writeSettled(rig.folders[0].appendingPathComponent("Deep/hidden.m4a"))
        try writeSettled(rig.folders[0].appendingPathComponent("first.wav"))
        await waitUntil { arrivals.names == ["first.wav"] }
        try writeSettled(rig.folders[0].appendingPathComponent("second.wav"))
        await waitUntil { arrivals.names == ["first.wav", "second.wav"] }
        await store.stopWatching()

        #expect(arrivals.names == ["first.wav", "second.wav"])
    }

    @Test("widening to subfolders restarts that folder alone and counts what is already inside them as seen")
    func wideningSkipsTheBacklog() async throws {
        let rig = try makeRig("widen", folderCount: 2, options: [depthOptions(depth: false), .default])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try writeSettled(rig.folders[0].appendingPathComponent("Archive/old.m4a"))

        let arrivals = Arrivals()
        var starts = 0
        let store = makeStore(rig, arrivals: arrivals)
        store.onFolderWatching = { starts += 1 }
        await waitUntil { starts == 2 }
        let other = try #require(store.watcher(for: rig.ids[1]))
        let first = try #require(store.watcher(for: rig.ids[0]))

        var options = store.options(for: rig.ids[0])
        options.includesSubfolders = true
        store.setOptions(options, for: rig.ids[0])
        await waitUntil { starts == 3 }

        #expect(store.watcher(for: rig.ids[1]) === other)
        #expect(store.watcher(for: rig.ids[0]) !== first)
        #expect(rig.defaults.data(forKey: "watchedFolders").flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) }?
            .first?.options.includesSubfolders == true)

        try writeSettled(rig.folders[0].appendingPathComponent("Archive/new.m4a"))
        await waitUntil { arrivals.names == ["new.m4a"] }
        await store.stopWatching()

        #expect(arrivals.names == ["new.m4a"])
    }

    @Test("narrowing to the folder itself stops reporting its subfolders")
    func narrowing() async throws {
        let rig = try makeRig("narrow")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        var starts = 0
        let store = makeStore(rig, arrivals: arrivals)
        store.onFolderWatching = { starts += 1 }
        await waitUntil { starts == 1 }

        var options = store.options(for: rig.ids[0])
        options.includesSubfolders = false
        store.setOptions(options, for: rig.ids[0])
        await waitUntil { starts == 2 }

        try writeSettled(rig.folders[0].appendingPathComponent("Deep/hidden.m4a"))
        try writeSettled(rig.folders[0].appendingPathComponent("top.wav"))
        await waitUntil { arrivals.names == ["top.wav"] }
        try writeSettled(rig.folders[0].appendingPathComponent("later.wav"))
        await waitUntil { arrivals.names == ["top.wav", "later.wav"] }
        await store.stopWatching()

        #expect(arrivals.names == ["top.wav", "later.wav"])
    }

    @Test("options without formats come back normalized, and the same options change nothing")
    func setOptionsNormalizes() async throws {
        let rig = try makeRig("normal")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var starts = 0
        let store = makeStore(rig, arrivals: Arrivals())
        store.onFolderWatching = { starts += 1 }
        await waitUntil { starts == 1 }

        var options = store.options(for: rig.ids[0])
        options.savesToLibrary = false
        store.setOptions(options, for: rig.ids[0])
        #expect(store.options(for: rig.ids[0]).savesToLibrary)

        options.exportPresetIDs = [ExportPreset.builtIn(for: .srt)!.id]
        store.setOptions(options, for: rig.ids[0])
        #expect(!store.options(for: rig.ids[0]).savesToLibrary)
        #expect(store.watcher(for: rig.ids[0]) != nil)
        await store.stopWatching()
    }

    @Test("a deleted preset leaves the folders that named it")
    func deletedPresetIsPruned() async throws {
        var options = WatchedFolderOptions()
        let gone = UUID()
        let kept = ExportPreset.builtIn(for: .txt)!.id
        options.exportPresetIDs = [gone, kept]
        let rig = try makeRig("prune", options: [options])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let store = makeStore(rig, arrivals: Arrivals())

        store.removeExportPreset(gone)

        #expect(store.options(for: rig.ids[0]).exportPresetIDs == [kept])
        await store.stopWatching()
    }

    @Test("Add Folder takes the folder the picker returns, and nothing when it is dismissed")
    func addFolderThroughThePicker() async throws {
        let rig = try makeRig("picker")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let extra = rig.root.appendingPathComponent("Extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let picker = TestFilePicker()
        let store = makeStore(rig, arrivals: Arrivals(), picker: picker)

        await store.addFolderFromPanel()
        #expect(store.folders.count == 1)

        await picker.queueFolderResponse(extra)
        await store.addFolderFromPanel()
        #expect(store.folders.map(\.displayPath).contains(extra.path))
        #expect(store.folders.last?.options == .default)
        await store.stopWatching()
    }

    @Test("Re-Add keeps the folder's options and takes the picker's answer")
    func reattachKeepsOptions() async throws {
        var options = WatchedFolderOptions()
        options.autoTranscribes = false
        let rig = try makeRig("readd", options: [options])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let picker = TestFilePicker()
        let store = makeStore(rig, arrivals: Arrivals(), picker: picker)

        await picker.queueFolderResponse(rig.folders[0])
        await store.reattachFromPanel(rig.ids[0])

        #expect(!store.options(for: rig.ids[0]).autoTranscribes)
        await store.stopWatching()
    }

    @Test("the store reads a folder saved before options existed")
    func loadsOldJSON() async throws {
        let rig = try makeRig("old")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let bookmark = try rig.folders[0].bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","bookmark":"\#(bookmark.base64EncodedString())","displayPath":"\#(rig.folders[0].path)"}]"#
        rig.defaults.set(Data(json.utf8), forKey: "watchedFolders")

        let store = makeStore(rig, arrivals: Arrivals())

        #expect(store.options(for: id) == .default)
        await store.stopWatching()
    }

    @Test("exported text files written into a watched folder start nothing")
    func exportedFilesStartNothing() async throws {
        let rig = try makeRig("exports")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let arrivals = Arrivals()
        var starts = 0
        let store = makeStore(rig, arrivals: arrivals)
        store.onFolderWatching = { starts += 1 }
        await waitUntil { starts == 1 }

        for name in ["Standup.srt", "Standup.txt", "Standup.json", "Sub/Standup.vtt"] {
            try writeSettled(rig.folders[0].appendingPathComponent(name))
        }
        try writeSettled(rig.folders[0].appendingPathComponent("first.wav"))
        await waitUntil { arrivals.names == ["first.wav"] }
        try writeSettled(rig.folders[0].appendingPathComponent("second.wav"))
        await waitUntil { arrivals.names == ["first.wav", "second.wav"] }
        await store.stopWatching()

        #expect(arrivals.names == ["first.wav", "second.wav"])
    }

    @Test("an exported text file is no media file, so a watched folder never offers it")
    func exportedFilesAreNotMedia() {
        for format in ExportFormat.allCases {
            let file = URL(fileURLWithPath: "/watched/Standup.\(format.fileExtension)")
            #expect(!FolderWatcher.isMediaFile(file), "\(format.fileExtension)")
        }
    }
}
