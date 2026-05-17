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
        } catch {
            NSLog("watched-folders: bookmark failed — \(error.localizedDescription)")
        }
    }

    func removeFolder(_ id: UUID) {
        let watcher = watchers.removeValue(forKey: id)
        let scopedURL = scopedURLs.removeValue(forKey: id)
        folders.removeAll { $0.id == id }
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

    private func startWatcher(for folder: WatchedFolder) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }
        guard !isStale, url.startAccessingSecurityScopedResource() else { return }
        scopedURLs[folder.id] = url

        let handler = onNewMediaFile
        let watcher = FolderWatcher(folderURL: url) { newURL in
            Task { @MainActor in handler(newURL) }
        }
        watchers[folder.id] = watcher
        Task { await watcher.start() }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "watchedFolders"),
              let stored = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return }
        folders = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: "watchedFolders")
        }
    }
}
