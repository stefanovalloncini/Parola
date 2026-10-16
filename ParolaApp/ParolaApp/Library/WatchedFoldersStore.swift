import AppKit
import Foundation
import Observation
import ParolaCore

struct WatchedFolder: Codable, Identifiable, Hashable {
    let id: UUID
    let bookmark: Data
    let displayPath: String
    var options: WatchedFolderOptions

    init(id: UUID = UUID(), bookmark: Data, displayPath: String, options: WatchedFolderOptions = .default) {
        self.id = id
        self.bookmark = bookmark
        self.displayPath = displayPath
        self.options = options
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        displayPath = try container.decode(String.self, forKey: .displayPath)
        options = try container.decodeIfPresent(WatchedFolderOptions.self, forKey: .options) ?? .default
    }

    var displayName: String { (displayPath as NSString).lastPathComponent }
}

@MainActor
@Observable
final class WatchedFoldersStore {
    private(set) var folders: [WatchedFolder] = []
    private(set) var lastError: String?
    var optionsSheetFolderID: UUID?
    /// Missing, trashed, unmounted or unreadable; tried again when a volume mounts and when the Mac wakes.
    private(set) var unavailableFolderIDs: Set<UUID> = []
    @ObservationIgnored private var watchers: [UUID: FolderWatcher] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var baselineWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var baselineDeadlines: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var baselineRewrites: Set<UUID> = []
    @ObservationIgnored private(set) var baselineSaves = 0
    @ObservationIgnored private var starts: [UUID: UUID] = [:]
    @ObservationIgnored private var carries: [UUID: Task<FolderWatcher.Baseline?, Never>] = [:]
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let baselines: WatchedFolderBaselines
    @ObservationIgnored private let watcherOptions: FolderWatcher.Options
    @ObservationIgnored private let baselineWriteDelay: Duration
    @ObservationIgnored private let baselineMaxWait: Duration
    @ObservationIgnored private let onNewMediaFile: @MainActor (URL) -> Void
    @ObservationIgnored private let picker: any FilePicker
    /// Called each time a folder's watch starts, so files waiting on an unreachable folder can go.
    @ObservationIgnored var onFolderWatching: (@MainActor () -> Void)?

    /// Every watcher shares `watcherOptions`' ledger, so a file moved between watched folders keeps its identity.
    init(
        defaults: UserDefaults = DefaultsStore.current,
        baselineDirectory: URL,
        watcherOptions: FolderWatcher.Options = FolderWatcher.Options(),
        baselineWriteDelay: Duration = .seconds(2),
        baselineMaxWait: Duration = .seconds(10),
        picker: any FilePicker = SystemFilePicker(),
        onNewMediaFile: @escaping @MainActor (URL) -> Void
    ) {
        self.picker = picker
        self.defaults = defaults
        self.baselines = WatchedFolderBaselines(directory: baselineDirectory)
        self.watcherOptions = watcherOptions
        self.baselineWriteDelay = baselineWriteDelay
        self.baselineMaxWait = baselineMaxWait
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
        Task { await addFolderFromPanel() }
    }

    func addFolderFromPanel() async {
        let message = String(localized: "Choose a folder to watch for new audio and video files.")
        guard let url = await picker.chooseFolder(message: message) else { return }
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
            lastError = String(localized: "Couldn't watch \(url.path): \(error.localizedDescription)")
        }
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        forget(id)
        baselines.remove(id)
        save()
    }

    func reattach(_ id: UUID) {
        Task { await reattachFromPanel(id) }
    }

    func reattachFromPanel(_ id: UUID) async {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let message = String(localized: "Pick \(folder.displayName) again to refresh permissions.")
        let start = URL(fileURLWithPath: folder.displayPath)
        guard let url = await picker.chooseFolder(message: message, startingAt: start) else { return }
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
            let refreshed = WatchedFolder(id: folder.id, bookmark: bookmark, displayPath: url.path, options: folder.options)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx] = refreshed
            }
            unavailableFolderIDs.remove(folder.id)
            cancelBaselineWrite(folder.id)
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
            lastError = String(localized: "Couldn't refresh \(url.path): \(error.localizedDescription)")
        }
    }

    func options(for id: UUID) -> WatchedFolderOptions {
        folders.first { $0.id == id }?.options ?? .default
    }

    /// A change of depth restarts that folder's watcher alone.
    func setOptions(_ options: WatchedFolderOptions, for id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let normalized = options.normalized
        let previous = folders[index].options
        guard normalized != previous else { return }
        folders[index].options = normalized
        save()
        guard normalized.includesSubfolders != previous.includesSubfolders else { return }
        restartWatcher(for: folders[index])
    }

    /// A preset that is gone leaves every folder's list; a folder left with no format saves to the library again.
    func pruneExportPresets(keeping ids: Set<UUID>) {
        var changed = false
        for index in folders.indices {
            var options = folders[index].options
            options.exportPresetIDs.removeAll { !ids.contains($0) }
            options = options.normalized
            if options != folders[index].options {
                folders[index].options = options
                changed = true
            }
        }
        if changed { save() }
    }

    private func restartWatcher(for folder: WatchedFolder) {
        cancelBaselineWrite(folder.id)
        startWatcher(
            for: folder,
            replacing: watchers.removeValue(forKey: folder.id),
            releasing: scopedURLs.removeValue(forKey: folder.id)
        )
    }

    func isUnavailable(_ id: UUID) -> Bool {
        unavailableFolderIDs.contains(id)
    }

    /// The watched folder a file it handed over lives in, and where that folder was when the watch started.
    func folder(containing url: URL) -> (id: UUID, root: URL)? {
        let path = Self.comparablePath(url)
        for (id, root) in scopedURLs {
            let prefix = Self.comparablePath(root)
            if path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") { return (id, root) }
        }
        return nil
    }

    /// `/var` and `/tmp` are links into `/private`, and the watcher reports the real path.
    private static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for linked in ["/private/var/", "/private/tmp/"] where path.hasPrefix(linked) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// In the order the folders were added, for the sidebar's warning.
    var unavailableFolders: [WatchedFolder] {
        folders.filter { unavailableFolderIDs.contains($0.id) }
    }

    /// Never mounts or prompts: an ejected share stays ejected and an offline server gets no attempt at each wake.
    func retryUnavailableFolders() {
        for folder in folders where unavailableFolderIDs.contains(folder.id)
            && watchers[folder.id] == nil && starts[folder.id] == nil {
            startWatcher(for: folder, mounting: false)
        }
    }

    /// After a settings reset or import, restarts only the folders whose entry changed.
    func reloadFromDefaults() {
        let previous = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        folders = []
        load()
        let kept = Set(folders.map(\.id))
        for id in previous.keys where !kept.contains(id) {
            forget(id)
        }
        baselines.removeAll(except: kept)
        for folder in folders where Self.needsRestart(from: previous[folder.id], to: folder) {
            let samePath = previous[folder.id]?.displayPath == folder.displayPath
            cancelBaselineWrite(folder.id)
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

    /// Every option but the depth is read when a file arrives, so only a depth change restarts a watcher.
    private static func needsRestart(from old: WatchedFolder?, to new: WatchedFolder) -> Bool {
        guard let old else { return true }
        return old.bookmark != new.bookmark || old.displayPath != new.displayPath
            || old.options.includesSubfolders != new.options.includesSubfolders
    }

    private func forget(_ id: UUID) {
        starts[id] = nil
        carries[id] = nil
        unavailableFolderIDs.remove(id)
        cancelBaselineWrite(id)
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

    /// A file a watcher handed over that the app couldn't use: a change to it offers it again.
    func offerAgainOnChange(_ url: URL) {
        for watcher in watchers.values {
            Task { await watcher.offerAgainOnChange(url) }
        }
    }

    /// Stops every watcher and releases the folders; the saved baselines stay for the next start.
    func stopWatching() async {
        starts.removeAll()
        carries.removeAll()
        let running = watchers
        let scopes = scopedURLs
        watchers.removeAll()
        scopedURLs.removeAll()
        for id in Array(baselineWrites.keys) { cancelBaselineWrite(id) }
        for (id, watcher) in running {
            await watcher.stop()
            scopes[id]?.stopAccessingSecurityScopedResource()
        }
    }

    /// The replaced watcher stops first, so a folder never has two; the new one starts from what it knew.
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
            let resolved = await Self.resolveBookmark(bookmark, displayPath: folder.displayPath, mounting: mounting)
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
                let sameFolder = self.folders.first { $0.id == id }?.displayPath == folder.displayPath
                if let carried, sameFolder, self.watchers[id] == nil {
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
            var watching = self.watcherOptions
            watching.recursive = current.options.includesSubfolders
            let watcher = FolderWatcher(
                folderURL: resolved.url,
                options: watching,
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
                self.onFolderWatching?()
            }
        }
    }

    /// The app isn't sandboxed, so a moved folder's stale bookmark still leads somewhere usable: save where.
    private func follow(_ folder: WatchedFolder, to resolved: ResolvedBookmark) {
        guard resolved.isStale || resolved.movedTo != nil else { return }
        let refreshed = WatchedFolder(
            id: folder.id,
            bookmark: resolved.freshBookmark ?? folder.bookmark,
            displayPath: resolved.movedTo ?? folder.displayPath,
            options: folder.options
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
        cancelBaselineWrite(id)
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

    /// Waits for changes to pause, but never longer than the max wait, so a long sync still gets saved.
    func scheduleBaselineWrite(for id: UUID) {
        let now = ContinuousClock.now
        let deadline = baselineDeadlines[id] ?? now + baselineMaxWait
        if baselineWrites[id] != nil, deadline <= now {
            baselineRewrites.insert(id)
            return
        }
        baselineWrites[id]?.cancel()
        baselineDeadlines[id] = deadline
        let delay = max(.zero, min(baselineWriteDelay, deadline - now))
        baselineWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let baseline = await self.watchers[id]?.baseline()
            guard !Task.isCancelled else { return }
            self.baselineWrites[id] = nil
            self.baselineDeadlines[id] = nil
            if let baseline {
                self.baselines.write(baseline, for: id)
                self.baselineSaves += 1
            }
            if self.baselineRewrites.remove(id) != nil {
                self.scheduleBaselineWrite(for: id)
            }
        }
    }

    private func cancelBaselineWrite(_ id: UUID) {
        baselineWrites.removeValue(forKey: id)?.cancel()
        baselineDeadlines[id] = nil
        baselineRewrites.remove(id)
    }

    /// For quit, when the main thread is blocked: saves each baseline still waiting to be written.
    func pendingBaselineFlush() -> @Sendable () async -> Void {
        let waiting = watchers.filter { baselineWrites[$0.key] != nil }
        let baselines = self.baselines
        return {
            for (id, watcher) in waiting {
                if let baseline = await watcher.baseline() {
                    baselines.writeNow(baseline, for: id)
                }
            }
            baselines.finishWrites()
        }
    }

    private struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
        let isDirectory: Bool
        /// Made only for a stale bookmark.
        let freshBookmark: Data?
        /// The folder's path when it is no longer where the display path says.
        let movedTo: String?
    }

    /// Reads the file system, so it belongs off the main thread with the rest of a resolution.
    nonisolated static func movedPath(of resolved: URL, from displayPath: String) -> String? {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        return canonical(resolved) == canonical(URL(fileURLWithPath: displayPath)) ? nil : resolved.path
    }

    // Off the main thread: resolving a security-scoped bookmark can block on mounting its volume,
    // which would hang launch for a watched folder on a disconnected drive.
    private nonisolated static func resolveBookmark(
        _ bookmark: Data, displayPath: String, mounting: Bool
    ) async -> ResolvedBookmark? {
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
                    url: url,
                    isStale: isStale,
                    isDirectory: isDirectory,
                    freshBookmark: freshBookmark,
                    movedTo: movedPath(of: url, from: displayPath)
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

/// One JSON file per folder, read and written on one serial queue so saves land in order.
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
            Self.save(baseline, to: url, in: directory)
        }
    }

    func writeNow(_ baseline: FolderWatcher.Baseline, for id: UUID) {
        let url = fileURL(for: id)
        let directory = directory
        Self.queue.sync {
            Self.save(baseline, to: url, in: directory)
        }
    }

    private static func save(_ baseline: FolderWatcher.Baseline, to url: URL, in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(baseline).write(to: url, options: .atomic)
        } catch {
            ParolaLog.error(.library, "watched folder baseline save failed", [.error: .error(error)])
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

    func finishWrites() {
        Self.queue.sync {}
    }

    /// Waits for every save queued before it; tests read the files after this.
    func settle() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume() }
        }
    }
}
