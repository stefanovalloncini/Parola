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
    /// Folders nothing is watching right now: missing, in the Trash, on a volume that isn't mounted,
    /// or no longer readable. They are tried again when a volume mounts and when the Mac wakes.
    private(set) var unavailableFolderIDs: Set<UUID> = []
    @ObservationIgnored private var watchers: [UUID: FolderWatcher] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var baselineWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var starts: [UUID: UUID] = [:]
    @ObservationIgnored private var carries: [UUID: Task<FolderWatcher.Baseline?, Never>] = [:]
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
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
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didWakeNotification] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryUnavailableFolders() }
            })
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
        folders.removeAll { $0.id == id }
        forget(id)
        baselines.remove(id)
        save()
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
        adopt(url, for: id)
    }

    /// Watches `url` for the folder `id` with a fresh bookmark, as Re-Add does after its panel.
    func adopt(_ url: URL, for id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
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
            unavailableFolderIDs.remove(folder.id)
            baselineWrites.removeValue(forKey: folder.id)?.cancel()
            // Another folder's baseline would flood it with arrivals; start it the way a new folder starts.
            if url.path != folder.displayPath {
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

    func isUnavailable(_ id: UUID) -> Bool {
        unavailableFolderIDs.contains(id)
    }

    /// Never mounts or prompts: an ejected share stays ejected and an offline server gets no attempt at each wake.
    func retryUnavailableFolders() {
        for folder in folders where unavailableFolderIDs.contains(folder.id)
            && watchers[folder.id] == nil && starts[folder.id] == nil {
            startWatcher(for: folder, mounting: false)
        }
    }

    /// Applies an external change to the "watchedFolders" defaults key (settings reset or import)
    /// without a relaunch. Only folders whose entry changed restart; one at the same path keeps
    /// what its watcher knew.
    func reloadFromDefaults() {
        let previous = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        folders = []
        load()
        let kept = Set(folders.map(\.id))
        for id in previous.keys where !kept.contains(id) {
            forget(id)
        }
        baselines.removeAll(except: kept)
        for folder in folders where previous[folder.id] != folder {
            let samePath = previous[folder.id]?.displayPath == folder.displayPath
            baselineWrites.removeValue(forKey: folder.id)?.cancel()
            if !samePath {
                baselines.remove(folder.id)
            }
            startWatcher(
                for: folder,
                replacing: watchers.removeValue(forKey: folder.id),
                releasing: scopedURLs.removeValue(forKey: folder.id),
                carriesBaseline: samePath
            )
        }
    }

    private func forget(_ id: UUID) {
        starts[id] = nil
        carries[id] = nil
        unavailableFolderIDs.remove(id)
        baselineWrites.removeValue(forKey: id)?.cancel()
        let scopedURL = scopedURLs.removeValue(forKey: id)
        guard let watcher = watchers.removeValue(forKey: id) else {
            scopedURL?.stopAccessingSecurityScopedResource()
            return
        }
        Task { @MainActor in
            await watcher.stop()
            scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    func watcher(for id: UUID) -> FolderWatcher? {
        watchers[id]
    }

    /// Stops every watcher and releases the folders; the saved baselines stay for the next start.
    func stopWatching() async {
        starts.removeAll()
        carries.removeAll()
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
        carriesBaseline: Bool = true,
        mounting: Bool = true
    ) {
        let id = folder.id
        let start = UUID()
        starts[id] = start
        let bookmark = folder.bookmark
        let baselines = self.baselines
        // A start that replaced nothing takes over what a start still in flight carried.
        let earlier = carriesBaseline ? carries[id] : nil
        let carry = Task<FolderWatcher.Baseline?, Never> {
            await previous?.stop()
            if carriesBaseline, let baseline = await previous?.baseline() { return baseline }
            return await earlier?.value
        }
        carries[id] = carry
        Task { [weak self] in
            let carried = await carry.value
            previousScope?.stopAccessingSecurityScopedResource()
            let resolved = await Self.resolveBookmark(bookmark, mounting: mounting)
            let saved = carried == nil ? await baselines.read(id) : nil
            guard let self else {
                if let carried { baselines.write(carried, for: id) }
                return
            }
            defer {
                if self.starts[id] == start { self.starts[id] = nil }
                if self.carries[id] == carry { self.carries[id] = nil }
            }
            guard self.starts[id] == start, let current = self.folders.first(where: { $0.id == id }) else {
                if let carried, self.folders.contains(where: { $0.id == id }) {
                    baselines.write(carried, for: id)
                }
                return
            }
            let baseline = carried ?? saved
            guard let resolved, resolved.isDirectory, !Self.isInTrash(resolved.url),
                  resolved.url.startAccessingSecurityScopedResource() else {
                if let carried { baselines.write(carried, for: id) }
                self.unavailableFolderIDs.insert(id)
                return
            }
            self.follow(current, to: resolved)

            let handler = self.onNewMediaFile
            let watcher = FolderWatcher(
                folderURL: resolved.url,
                options: self.watcherOptions,
                onBaselineChange: { [weak self] in
                    Task { @MainActor in self?.scheduleBaselineWrite(for: id) }
                },
                onStateChange: { [weak self] state in
                    Task { @MainActor in await self?.watcherStopped(id, state: state) }
                },
                onNewMediaFile: { newURL in
                    Task { @MainActor in handler(newURL) }
                }
            )
            self.watchers[id] = watcher
            self.scopedURLs[id] = resolved.url
            await watcher.start(baseline: baseline)
            guard self.watchers[id] === watcher else { return }
            if await watcher.state == .unavailable {
                self.watchers[id] = nil
                self.scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
                if let carried { baselines.write(carried, for: id) }
                self.unavailableFolderIDs.insert(id)
            } else {
                self.unavailableFolderIDs.remove(id)
            }
        }
    }

    /// A renamed or moved folder, or one on a volume mounted somewhere new, resolves with a stale
    /// bookmark. The app isn't sandboxed, so the resolved folder is usable: keep watching it and
    /// save a fresh bookmark and path.
    private func follow(_ folder: WatchedFolder, to resolved: ResolvedBookmark) {
        let moved = Self.canonicalPath(resolved.url) != Self.canonicalPath(URL(fileURLWithPath: folder.displayPath))
        guard resolved.isStale || moved else { return }
        let refreshed = WatchedFolder(
            id: folder.id,
            bookmark: resolved.freshBookmark ?? folder.bookmark,
            displayPath: moved ? resolved.url.path : folder.displayPath
        )
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = refreshed
        save()
    }

    /// A renamed or deleted folder is looked for at once; an unmounted one waits for a mount.
    private func watcherStopped(_ id: UUID, state: FolderWatcher.State) async {
        guard state == .lost || state == .unmounted, let watcher = watchers[id], await watcher.state == state,
              watchers[id] === watcher, let folder = folders.first(where: { $0.id == id }) else { return }
        watchers[id] = nil
        baselineWrites.removeValue(forKey: id)?.cancel()
        let scopedURL = scopedURLs.removeValue(forKey: id)
        if state == .lost {
            startWatcher(for: folder, replacing: watcher, releasing: scopedURL, mounting: false)
            return
        }
        unavailableFolderIDs.insert(id)
        if let baseline = await watcher.baseline() {
            baselines.write(baseline, for: id)
        }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func scheduleBaselineWrite(for id: UUID) {
        baselineWrites[id]?.cancel()
        let delay = baselineWriteDelay
        baselineWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let watcher = self.watchers[id] else { return }
            let baseline = await watcher.baseline()
            guard !Task.isCancelled, let baseline else { return }
            self.baselines.write(baseline, for: id)
            self.baselineWrites[id] = nil
        }
    }

    private struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
        let isDirectory: Bool
        /// Made only for a stale bookmark.
        let freshBookmark: Data?
    }

    // Off the main thread: resolving a security-scoped bookmark can block on mounting its volume,
    // which would hang launch for a watched folder on a disconnected drive.
    private nonisolated static func resolveBookmark(_ bookmark: Data, mounting: Bool) async -> ResolvedBookmark? {
        let options: URL.BookmarkResolutionOptions = mounting
            ? .withSecurityScope
            : [.withSecurityScope, .withoutMounting, .withoutUI]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let freshBookmark = isStale
                    ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    : nil
                continuation.resume(returning: ResolvedBookmark(
                    url: url, isStale: isStale, isDirectory: isDirectory, freshBookmark: freshBookmark
                ))
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
