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
        Task { await chooseAutoExportFolderFromPanel() }
    }

    func chooseAutoExportFolderFromPanel() async {
        let start = autoExportFolder.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let chosen = await filePicker.chooseFolder(
            message: nil, startingAt: start, canCreateDirectories: true, prompt: String(localized: "Choose")
        )
        guard let chosen else { return }
        setAutoExportFolder(chosen)
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

    /// Off main, since resolving can wait on the folder's volume; a stale bookmark comes back re-minted.
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

    /// A file's exports go beside it; a take's or a link's go to the chosen folder, under the entry's title.
    @discardableResult
    func runAutoExports(
        transcript: Transcript, audioSource: URL?, source: EntrySource, entry: LibraryEntry?, title: String? = nil,
        folderOptions: WatchedFolderOptions? = nil
    ) -> Task<Void, Never>? {
        guard let exports = exportTranscript(
            transcript, audioSource: audioSource, source: source, entry: entry, title: title, folderOptions: folderOptions
        ) else { return nil }
        return Task { _ = await exports.value }
    }

    /// The auto-export rules plus, for a watched file, its folder's formats, planned together so no file is written twice.
    func exportTranscript(
        _ transcript: Transcript, audioSource: URL?, source: EntrySource, entry: LibraryEntry?, title: String?,
        folderOptions: WatchedFolderOptions?
    ) -> Task<[ExportJobResult], Never>? {
        let own = folderOptions?.presets(in: exportPresets) ?? []
        let toExportFolder = folderOptions?.exportsToAutoExportFolder == true
        let name = entry.map(LibraryEntryDisplay.title(for:))
            ?? title
            ?? audioSource?.deletingPathExtension().lastPathComponent
            ?? ""
        let owner = entry?.id ?? audioSource?.path ?? UUID().uuidString
        switch sidecarRoute(audioSource: audioSource, source: source) {
        case .besideSource(let url):
            let beside = writeSidecars(transcript, presets: toExportFolder ? [] : own, source: SidecarSource(besideFile: url))
            let elsewhere = toExportFolder
                ? writeToAutoExportFolder(
                    transcript, fileExtension: url.pathExtension, name: name, owner: owner, presets: own, appliesRules: false
                )
                : nil
            guard beside != nil || elsewhere != nil else { return nil }
            return Task { await (beside?.value ?? []) + (elsewhere?.value ?? []) }
        case .autoExportFolder:
            return writeToAutoExportFolder(
                transcript, fileExtension: audioSource?.pathExtension ?? "vtt", name: name, owner: owner,
                presets: own, appliesRules: true
            )
        case .none:
            return nil
        }
    }

    private func writeToAutoExportFolder(
        _ transcript: Transcript, fileExtension: String, name: String, owner: String,
        presets: [ExportPreset], appliesRules: Bool
    ) -> Task<[ExportJobResult], Never>? {
        let ruled = appliesRules
            ? AutoExportEngine.plannedPresets(rules: autoExportRules, sourceExtension: fileExtension, presets: exportPresets)
            : []
        guard !(ruled.isEmpty && presets.isEmpty) else { return nil }
        guard let folder = autoExportFolder else {
            noteAutoExport(.autoExportFolderMissing)
            return nil
        }
        return Task { [weak self] in
            guard case .resolved(let url, let refreshed) = await Self.resolve(folder) else {
                self?.noteAutoExport(.autoExportFolderUnavailable)
                return []
            }
            guard let self else { return [] }
            if let refreshed, autoExportFolder == folder { autoExportFolder = refreshed }
            let jobs = SidecarExportPlanner.plan(
                presets: presets, rules: appliesRules ? autoExportRules : [], library: exportPresets,
                source: SidecarSource(fileExtension: fileExtension, folder: url, baseName: name, owner: owner)
            )
            let scoped = url.startAccessingSecurityScopedResource()
            let results = await ExportRunner.run(jobs, transcript: transcript)
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let error = results.lazy.compactMap(\.error).first {
                noteAutoExport(.autoExportFailed(error))
            }
            return results
        }
    }

    enum SidecarRoute: Equatable {
        case besideSource(URL)
        case autoExportFolder
        case none
    }

    /// A file in a folder that gets cleared, like a Shortcuts input, goes the folder route like a take.
    func sidecarRoute(audioSource: URL?, source: EntrySource) -> SidecarRoute {
        switch source {
        case .file:
            guard let audioSource else { return .none }
            return Self.isInside(audioSource, anyOf: sweptFolders()) ? .autoExportFolder : .besideSource(audioSource)
        case .microphone, .systemAudio, .web:
            return .autoExportFolder
        }
    }

    nonisolated static func isInside(_ url: URL, anyOf folders: [URL]) -> Bool {
        let path = comparablePath(url)
        return folders.contains { folder in
            let prefix = comparablePath(folder)
            return path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }
    }

    /// `/var` and `/tmp` are links into `/private`, and a path reaches us spelled either way.
    private nonisolated static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for linked in ["/private/var/", "/private/tmp/"] where path.hasPrefix(linked) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Once per launch, and again after a new folder is chosen: every take would otherwise say the same thing.
    func noteAutoExport(_ notice: ExportNotice) {
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
