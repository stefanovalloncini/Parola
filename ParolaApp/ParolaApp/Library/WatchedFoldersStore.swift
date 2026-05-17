import AppKit
import Foundation
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
final class WatchedFoldersStore: ObservableObject {
    @Published private(set) var folders: [WatchedFolder] = []
    @Published private(set) var lastError: String?
    @Published private(set) var staleFolderIDs: Set<UUID> = []
    private var watchers: [UUID: FolderWatcher] = [:]
    private var scopedURLs: [UUID: URL] = [:]
    private let onNewMediaFile: @MainActor (URL) -> Void

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

    private func startWatcher(for folder: WatchedFolder) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            staleFolderIDs.insert(folder.id)
            return
        }
        guard !isStale, url.startAccessingSecurityScopedResource() else {
            staleFolderIDs.insert(folder.id)
            return
        }
        staleFolderIDs.remove(folder.id)
        scopedURLs[folder.id] = url

        let handler = onNewMediaFile
        let watcher = FolderWatcher(folderURL: url) { newURL in
            Task { @MainActor in handler(newURL) }
        }
        watchers[folder.id] = watcher
        Task { await watcher.start() }
    }

    private func load() {
        if let stored = AppModel.readJSON([WatchedFolder].self, forKey: "watchedFolders") {
            folders = stored
        }
    }

    private func save() {
        AppModel.writeJSON(folders, forKey: "watchedFolders")
    }

    func dismissError() {
        lastError = nil
    }
}
