import AppKit
import Foundation
import Observation
import ParolaCore

struct WatchedFolder: Codable, Identifiable, Hashable {
    let id: UUID
    let bookmark: Data
    let displayPath: String

    init(id: UUID = UUID(), bookmark: Data, displayPath: String) {
        self.id = id
        self.bookmark = bookmark
        self.displayPath = displayPath
    }

    var displayName: String { (displayPath as NSString).lastPathComponent }
}

@MainActor
@Observable
final class WatchedFoldersStore {
    private(set) var folders: [WatchedFolder] = []
    private(set) var lastError: String?
    private(set) var staleFolderIDs: Set<UUID> = []
    @ObservationIgnored private var watchers: [UUID: FolderWatcher] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var baselineWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchEpoch = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let baselines: WatchedFolderBaselines
    @ObservationIgnored private let watcherOptions: FolderWatcher.Options
    @ObservationIgnored private let baselineWriteDelay: Duration
    @ObservationIgnored private let onNewMediaFile: @MainActor (URL) -> Void

    /// Every watcher gets `watcherOptions`, so they share its ledger and a file moved between two
    /// watched folders keeps its identity.
    init(
        defaults: UserDefaults = DefaultsStore.current,
        baselineDirectory: URL,
        watcherOptions: FolderWatcher.Options = FolderWatcher.Options(),
        baselineWriteDelay: Duration = .seconds(2),
        onNewMediaFile: @escaping @MainActor (URL) -> Void
    ) {
        self.defaults = defaults
        self.baselines = WatchedFolderBaselines(directory: baselineDirectory)
        self.watcherOptions = watcherOptions
        self.baselineWriteDelay = baselineWriteDelay
        self.onNewMediaFile = onNewMediaFile
        load()
        baselines.removeAll(except: Set(folders.map(\.id)))
        for folder in folders {
            startWatcher(for: folder)
        }
    }

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to watch for new audio and video files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel can still hand back a file via the go-to-folder field despite canChooseFiles=false.
        guard url.hasDirectoryPath else {
            lastError = "\(url.lastPathComponent) isn't a folder."
            return
        }
        guard !folders.contains(where: { $0.displayPath == url.path }) else {
            lastError = "Already watching \(url.path)."
            return
        }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folder = WatchedFolder(bookmark: bookmark, displayPath: url.path)
            folders.append(folder)
            save()
            startWatcher(for: folder)
            lastError = nil
        } catch {
            lastError = "Couldn't watch \(url.path): \(error.localizedDescription)"
        }
    }

    func removeFolder(_ id: UUID) {
        let watcher = watchers.removeValue(forKey: id)
        let scopedURL = scopedURLs.removeValue(forKey: id)
        folders.removeAll { $0.id == id }
        staleFolderIDs.remove(id)
        baselineWrites.removeValue(forKey: id)?.cancel()
        baselines.remove(id)
        save()
        if let watcher {
            Task { @MainActor in
                await watcher.stop()
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        } else {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    func reattach(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder.displayPath)
        panel.message = "Pick \(folder.displayName) again to refresh permissions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let refreshed = WatchedFolder(id: folder.id, bookmark: bookmark, displayPath: url.path)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx] = refreshed
            }
            staleFolderIDs.remove(folder.id)
            // Another folder's baseline would flood it with arrivals; start it the way a new folder starts.
            if url.path != folder.displayPath {
                baselineWrites.removeValue(forKey: folder.id)?.cancel()
                baselines.remove(folder.id)
            }
            save()
            startWatcher(
                for: refreshed,
                replacing: watchers.removeValue(forKey: folder.id),
                releasing: scopedURLs.removeValue(forKey: folder.id),
                carriesBaseline: url.path == folder.displayPath
            )
            lastError = nil
        } catch {
            lastError = "Couldn't refresh \(url.path): \(error.localizedDescription)"
        }
    }

    func isStale(_ id: UUID) -> Bool {
        staleFolderIDs.contains(id)
    }

    /// Applies an external change to the "watchedFolders" defaults key (settings reset or import)
    /// without a relaunch. A folder that is still listed keeps what its watcher knew, so a file
    /// that was settling arrives and one already imported doesn't come back.
    func reloadFromDefaults() {
        watchEpoch += 1
        let previousWatchers = watchers
        let previousScopes = scopedURLs
        watchers.removeAll()
        scopedURLs.removeAll()
        staleFolderIDs.removeAll()
        for task in baselineWrites.values { task.cancel() }
        baselineWrites.removeAll()
        folders = []
        load()
        let kept = Set(folders.map(\.id))
        for (id, watcher) in previousWatchers where !kept.contains(id) {
            let scopedURL = previousScopes[id]
            Task { @MainActor in
                await watcher.stop()
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        }
        baselines.removeAll(except: kept)
        for folder in folders {
            startWatcher(for: folder, replacing: previousWatchers[folder.id], releasing: previousScopes[folder.id])
        }
    }

    /// Stops every watcher and releases the folders; the saved baselines stay for the next start.
    func stopWatching() async {
        watchEpoch += 1
        let running = watchers
        let scopes = scopedURLs
        watchers.removeAll()
        scopedURLs.removeAll()
        for task in baselineWrites.values { task.cancel() }
        baselineWrites.removeAll()
        for (id, watcher) in running {
            await watcher.stop()
            scopes[id]?.stopAccessingSecurityScopedResource()
        }
    }

    /// The watcher being replaced stops, and its folder access ends, before the new one starts, so a
    /// folder never has two; by default the new one picks up from what the old one knew.
    private func startWatcher(
        for folder: WatchedFolder,
        replacing previous: FolderWatcher? = nil,
        releasing previousScope: URL? = nil,
        carriesBaseline: Bool = true
    ) {
        let epoch = watchEpoch
        let bookmark = folder.bookmark
        let baselines = self.baselines
        Task { [weak self] in
            let carried = carriesBaseline ? await previous?.baseline() : nil
            await previous?.stop()
            previousScope?.stopAccessingSecurityScopedResource()
            let resolved = await Self.resolveBookmark(bookmark)
            var baseline = carried
            if baseline == nil {
                baseline = await baselines.read(folder.id)
            }
            guard let self else { return }
            guard epoch == self.watchEpoch, self.folders.contains(where: { $0.id == folder.id }) else { return }
            guard let resolved, !resolved.isStale, resolved.isDirectory,
                  resolved.url.startAccessingSecurityScopedResource() else {
                self.staleFolderIDs.insert(folder.id)
                return
            }
            self.staleFolderIDs.remove(folder.id)
            self.scopedURLs[folder.id] = resolved.url

            let handler = self.onNewMediaFile
            let id = folder.id
            let watcher = FolderWatcher(
                folderURL: resolved.url,
                options: self.watcherOptions,
                onBaselineChange: { [weak self] in
                    Task { @MainActor in self?.scheduleBaselineWrite(for: id) }
                },
                onNewMediaFile: { newURL in
                    Task { @MainActor in handler(newURL) }
                }
            )
            self.watchers[folder.id] = watcher
            Task { await watcher.start(baseline: baseline) }
        }
    }

    private func scheduleBaselineWrite(for id: UUID) {
        baselineWrites[id]?.cancel()
        let delay = baselineWriteDelay
        baselineWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let watcher = self.watchers[id] else { return }
            let baseline = await watcher.baseline()
            guard !Task.isCancelled else { return }
            self.baselines.write(baseline, for: id)
            self.baselineWrites[id] = nil
        }
    }

    // Off the main thread: resolving a security-scoped bookmark can block on mounting its volume,
    // which would hang launch for a watched folder on a disconnected drive.
    private nonisolated static func resolveBookmark(_ bookmark: Data) async -> (url: URL, isStale: Bool, isDirectory: Bool)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                continuation.resume(returning: (url, isStale, isDirectory))
            }
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: "watchedFolders") else { return }
        if let stored = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = stored
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: "watchedFolders")
        }
    }

    func dismissError() {
        lastError = nil
    }
}

/// One JSON file per watched folder. Every read and write goes through one serial queue, so a later
/// save never lands before an earlier one.
struct WatchedFolderBaselines: Sendable {
    let directory: URL
    private static let queue = DispatchQueue(label: "app.parola.watched-folder-baselines", qos: .utility)

    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func read(_ id: UUID) async -> FolderWatcher.Baseline? {
        let url = fileURL(for: id)
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(FolderWatcher.Baseline.self, from: $0) })
            }
        }
    }

    func write(_ baseline: FolderWatcher.Baseline, for id: UUID) {
        let url = fileURL(for: id)
        let directory = directory
        Self.queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(baseline).write(to: url, options: .atomic)
            } catch {
                ParolaLog.error(.library, "watched folder baseline save failed", [.error: .error(error)])
            }
        }
    }

    func remove(_ id: UUID) {
        let url = fileURL(for: id)
        Self.queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAll(except kept: Set<UUID>) {
        let directory = directory
        Self.queue.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".json") {
                guard let id = UUID(uuidString: String(name.dropLast(5))), !kept.contains(id) else { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Waits for every save queued before it; tests read the files after this.
    func settle() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume() }
        }
    }
}
