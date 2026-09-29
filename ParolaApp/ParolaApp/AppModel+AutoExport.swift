import Foundation
import SwiftUI
import AppKit
import ParolaCore

extension AppModel {

    func loadAutoExportRules() {
        autoExportRules = readJSON([AutoExportRule].self, forKey: "autoExportRules") ?? []
    }

    func saveAutoExportRules() {
        writeJSON(autoExportRules, forKey: "autoExportRules")
    }

    /// Takes a folder the user picked in an open panel, which needs no privacy prompt, and keeps it as a bookmark.
    @discardableResult
    func setAutoExportFolder(_ url: URL) -> Bool {
        guard let bookmark = Self.folderBookmark(for: url) else { return false }
        autoExportFolder = AutoExportFolder(bookmark: bookmark, path: url.path)
        autoExportNoticeShown = false
        return true
    }

    func chooseAutoExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let folder = autoExportFolder { panel.directoryURL = URL(fileURLWithPath: folder.path, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setAutoExportFolder(url)
    }

    /// A process that can't mint a security-scoped bookmark still gets a plain one that resolves.
    nonisolated static func folderBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    enum AutoExportFolderResolution: Sendable {
        case resolved(URL, refreshed: AutoExportFolder?)
        case unavailable
    }

    /// Off the main thread: resolving can wait on the folder's volume. A stale bookmark that still finds
    /// the folder comes back re-minted.
    @concurrent
    nonisolated static func resolve(_ folder: AutoExportFolder) async -> AutoExportFolderResolution {
        var isStale = false
        let resolved = (try? URL(
            resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &isStale
        )) ?? (try? URL(
            resolvingBookmarkData: folder.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale
        ))
        guard let url = resolved else { return .unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable
        }
        let refreshed = isStale ? folderBookmark(for: url).map { AutoExportFolder(bookmark: $0, path: url.path) } : nil
        return .resolved(url, refreshed: refreshed)
    }

    /// The auto-export rules for one finished run. A file's exports go beside it; a take's or a link's go to
    /// the folder the user chose, under the entry's title, and wait for that choice until it is made.
    @discardableResult
    func runAutoExports(
        transcript: Transcript, audioSource: URL?, source: EntrySource, entry: LibraryEntry?, title: String? = nil
    ) -> Task<Void, Never>? {
        switch sidecarRoute(audioSource: audioSource, source: source) {
        case .besideSource(let url):
            let written = writeSidecars(transcript, presets: [], source: SidecarSource(besideFile: url))
            return written.map { task in Task { _ = await task.value } }
        case .autoExportFolder:
            let fileExtension = audioSource?.pathExtension ?? "vtt"
            let planned = AutoExportEngine.plannedPresets(
                rules: autoExportRules, sourceExtension: fileExtension, presets: exportPresets
            )
            guard !planned.isEmpty else { return nil }
            guard let folder = autoExportFolder else {
                noteAutoExport(.autoExportFolderMissing)
                return nil
            }
            let name = entry.map(LibraryEntryDisplay.title(for:))
                ?? title
                ?? audioSource?.deletingPathExtension().lastPathComponent
                ?? ""
            let owner = entry?.id ?? UUID().uuidString
            return Task { [weak self] in
                guard case .resolved(let url, let refreshed) = await Self.resolve(folder) else {
                    self?.noteAutoExport(.autoExportFolderUnavailable)
                    return
                }
                guard let self else { return }
                if let refreshed, autoExportFolder == folder { autoExportFolder = refreshed }
                let jobs = SidecarExportPlanner.plan(
                    presets: [], rules: autoExportRules, library: exportPresets,
                    source: SidecarSource(fileExtension: fileExtension, folder: url, baseName: name, owner: owner)
                )
                let scoped = url.startAccessingSecurityScopedResource()
                let results = await ExportRunner.run(jobs, transcript: transcript)
                if scoped { url.stopAccessingSecurityScopedResource() }
                if let error = results.lazy.compactMap(\.error).first {
                    noteAutoExport(.autoExportFailed(error))
                }
            }
        case .none:
            return nil
        }
    }

    enum SidecarRoute: Equatable {
        case besideSource(URL)
        case autoExportFolder
        case none
    }

    /// Fetched captions have no audio: they take the folder route, as their link would.
    func sidecarRoute(audioSource: URL?, source: EntrySource) -> SidecarRoute {
        switch source {
        case .file:
            return audioSource.map(SidecarRoute.besideSource) ?? .none
        case .microphone, .systemAudio, .web:
            return .autoExportFolder
        }
    }

    /// Once per launch, and again after a new folder is chosen: every take would otherwise say the same thing.
    private func noteAutoExport(_ notice: ExportNotice) {
        guard !autoExportNoticeShown else { return }
        autoExportNoticeShown = true
        exportNotice = notice
    }

    /// The presets named here and the auto-export rules for this source, planned together so no file is written twice.
    @discardableResult
    func writeSidecars(
        _ transcript: Transcript, presets: [ExportPreset], source: SidecarSource
    ) -> Task<[ExportJobResult], Never>? {
        let jobs = SidecarExportPlanner.plan(
            presets: presets, rules: autoExportRules, library: exportPresets, source: source
        )
        guard !jobs.isEmpty else { return nil }
        return Task { await ExportRunner.run(jobs, transcript: transcript) }
    }
}
