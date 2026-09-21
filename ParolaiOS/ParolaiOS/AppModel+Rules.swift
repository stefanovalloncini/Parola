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
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(entry.id)
                let exportsDir = library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let base = (entry.title as NSString).deletingPathExtension
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
}
