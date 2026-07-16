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
    @ObservationIgnored private var watchEpoch = 0
    @ObservationIgnored private let onNewMediaFile: @MainActor (URL) -> Void

    init(onNewMediaFile: @escaping @MainActor (URL) -> Void) {
        self.onNewMediaFile = onNewMediaFile
        load()
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
            save()
            startWatcher(for: refreshed)
            lastError = nil
        } catch {
            lastError = "Couldn't refresh \(url.path): \(error.localizedDescription)"
        }
    }

    func isStale(_ id: UUID) -> Bool {
        staleFolderIDs.contains(id)
    }

    /// Applies an external change to the "watchedFolders" defaults key (settings reset or import)
    /// without a relaunch: stops every watcher, releases scoped URLs, re-reads defaults, restarts.
    func reloadFromDefaults() {
        watchEpoch += 1
        for (id, watcher) in watchers {
            let scopedURL = scopedURLs.removeValue(forKey: id)
            Task { @MainActor in
                await watcher.stop()
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        }
        watchers.removeAll()
        scopedURLs.removeAll()
        staleFolderIDs.removeAll()
        folders = []
        load()
        for folder in folders {
            startWatcher(for: folder)
        }
    }

    private func startWatcher(for folder: WatchedFolder) {
        let epoch = watchEpoch
        let bookmark = folder.bookmark
        Task { [weak self] in
            // Detached: resolving a security-scoped bookmark can block on mounting its volume,
            // which would hang launch for a watched folder on a disconnected drive.
            let resolved = await Task.detached(priority: .userInitiated) { () -> (url: URL, isStale: Bool)? in
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else { return nil }
                return (url, isStale)
            }.value
            guard let self else { return }
            guard epoch == self.watchEpoch, self.folders.contains(where: { $0.id == folder.id }) else { return }
            guard let resolved, !resolved.isStale, resolved.url.startAccessingSecurityScopedResource() else {
                self.staleFolderIDs.insert(folder.id)
                return
            }
            self.staleFolderIDs.remove(folder.id)
            self.scopedURLs[folder.id] = resolved.url

            let handler = self.onNewMediaFile
            let watcher = FolderWatcher(folderURL: resolved.url) { newURL in
                Task { @MainActor in handler(newURL) }
            }
            self.watchers[folder.id] = watcher
            Task { await watcher.start() }
        }
    }

    private func load() {
        guard let data = DefaultsStore.current.data(forKey: "watchedFolders") else { return }
        if let stored = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = stored
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            DefaultsStore.current.set(data, forKey: "watchedFolders")
        }
    }

    func dismissError() {
        lastError = nil
    }
}
