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

    /// Where a take's or a link's files go.
    var autoExportFolderURL: URL {
        if !autoExportFolderPath.isEmpty { return URL(fileURLWithPath: autoExportFolderPath, isDirectory: true) }
        return Self.defaultAutoExportFolder(libraryURL: library.libraryURL)
    }

    /// A library opened with `--library` (the sandbox, a test) keeps its exports beside itself, so only
    /// the real library writes into Documents.
    nonisolated static func defaultAutoExportFolder(libraryURL: URL) -> URL {
        libraryURL == LibraryStore.defaultLibraryURL
            ? URL.documentsDirectory.appendingPathComponent("Parola Exports", isDirectory: true)
            : libraryURL.appendingPathComponent("Exports", isDirectory: true)
    }

    func chooseAutoExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = autoExportFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        autoExportFolderPath = url.path
    }

    /// The auto-export rules for one finished run. A file's exports go beside it; a take's audio sits in
    /// the recording scratch folder and a link's in a temporary one, so theirs go to the auto-export
    /// folder under the entry's title.
    func runAutoExports(
        transcript: Transcript, audioSource: URL?, source: EntrySource, entry: LibraryEntry?, title: String? = nil
    ) {
        guard let target = sidecarSource(audioSource: audioSource, source: source, entry: entry, title: title) else {
            return
        }
        writeSidecars(transcript, presets: [], source: target)
    }

    func sidecarSource(audioSource: URL?, source: EntrySource, entry: LibraryEntry?, title: String?) -> SidecarSource? {
        switch source {
        case .file:
            return audioSource.map(SidecarSource.init(besideFile:))
        case .microphone, .systemAudio, .web:
            let name = entry.map(LibraryEntryDisplay.title(for:))
                ?? title
                ?? audioSource?.deletingPathExtension().lastPathComponent
                ?? ""
            return SidecarSource(
                // Fetched captions have no audio; they arrive as WebVTT.
                fileExtension: audioSource?.pathExtension ?? "vtt",
                folder: autoExportFolderURL,
                baseName: name,
                owner: entry?.id ?? UUID().uuidString
            )
        }
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
