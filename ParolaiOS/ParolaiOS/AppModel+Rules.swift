import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func loadAutoExportRules() {
        guard let data = defaults.data(forKey: "autoExportRules"),
              let rules = try? JSONDecoder().decode([AutoExportRule].self, from: data) else { return }
        autoExportRules = rules
    }

    func saveAutoExportRules() {
        if let data = try? JSONEncoder().encode(autoExportRules) {
            defaults.set(data, forKey: "autoExportRules")
        }
    }

    func loadIgnoredSegmentRules() {
        guard let data = defaults.data(forKey: "ignoredSegmentRules"),
              let rules = try? JSONDecoder().decode([IgnoredSegmentRule].self, from: data) else { return }
        ignoredSegmentRules = rules
    }

    func saveIgnoredSegmentRules() {
        if let data = try? JSONEncoder().encode(ignoredSegmentRules) {
            defaults.set(data, forKey: "ignoredSegmentRules")
        }
    }

    func loadFindReplaceRules() {
        guard let data = defaults.data(forKey: "findReplaceRules"),
              let rules = try? JSONDecoder().decode([FindReplaceRule].self, from: data) else { return }
        findReplaceRules = rules
    }

    func saveFindReplaceRules() {
        if let data = try? JSONEncoder().encode(findReplaceRules) {
            defaults.set(data, forKey: "findReplaceRules")
        }
    }

    func runAutoExports(for entry: LibraryEntry) {
        let rules = autoExportRules
        let fileExtension = (entry.manifest.originalAudioName as NSString).pathExtension
        let planned = AutoExportEngine.plannedPresets(
            rules: rules, sourceExtension: fileExtension, presets: ExportPreset.formatPresets
        )
        guard !planned.isEmpty else { return }
        // The add cached what it saved, so this load decodes nothing.
        Task.detached(priority: .utility) { [library] in
            let loaded: LoadedEntry
            do {
                loaded = try await library.load(entry.id)
            } catch {
                ParolaLog.error(.export, "auto-export could not start", [.error: .error(error)])
                return
            }
            let exportsDir = library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
            let base = Self.unusedExportBase(
                for: entry.title, extensions: planned.map(\.spec.format.fileExtension), in: exportsDir
            )
            let jobs = SidecarExportPlanner.plan(
                presets: [], rules: rules, library: ExportPreset.formatPresets,
                source: SidecarSource(fileExtension: fileExtension, folder: exportsDir, baseName: base)
            )
            _ = await ExportRunner.run(jobs, transcript: loaded.document.transcript)
        }
    }

    /// Imports that share a file name share a title, so the second one's exports become "Title 2", "Title 3"…
    nonisolated static func unusedExportBase(
        for rawTitle: String,
        extensions: [String],
        in directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
        // A renamed entry's title can hold a slash, which would name a folder, or start with a dot, which hides the file.
        let cleaned = String(rawTitle.replacingOccurrences(of: "/", with: "-").drop { $0 == "." })
        let title = cleaned.isEmpty ? "Transcript" : cleaned
        func free(_ base: String) -> Bool {
            !extensions.contains { exists(directory.appendingPathComponent("\(base).\($0)")) }
        }
        if free(title) { return title }
        for counter in 2..<1000 where free("\(title) \(counter)") {
            return "\(title) \(counter)"
        }
        return "\(title) \(UUID().uuidString)"
    }
}
