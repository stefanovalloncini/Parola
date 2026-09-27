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
        let ext = (entry.manifest.originalAudioName as NSString).pathExtension
        let presets = AutoExportEngine.plannedPresets(
            rules: autoExportRules,
            sourceExtension: ext,
            presets: ExportPreset.formatPresets
        )
        guard !presets.isEmpty else { return }
        // The add cached what it saved, so this load decodes nothing.
        Task.detached(priority: .utility) { [library] in
            do {
                let loaded = try await library.load(entry.id)
                let exportsDir = library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let base = Self.unusedExportBase(
                    for: entry.title, extensions: presets.map(\.spec.format.fileExtension), in: exportsDir
                )
                for preset in presets {
                    let target = exportsDir.appendingPathComponent("\(base).\(preset.spec.format.fileExtension)")
                    let data = try Exporters.exporter(for: preset.spec).render(loaded.document.transcript)
                    try data.write(to: target, options: .atomic)
                }
            } catch {
                // Best-effort; primary transcription already saved.
            }
        }
    }

    /// Imports that share a file name share a title, so the second one's exports become "Title 2", "Title 3"…
    nonisolated static func unusedExportBase(
        for title: String,
        extensions: [String],
        in directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
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
