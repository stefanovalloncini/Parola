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
        let formats = AutoExportEngine.plannedFormats(rules: autoExportRules, sourceExtension: ext)
        guard !formats.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(entry.id)
                let exportsDir = library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let base = (entry.title as NSString).deletingPathExtension
                for format in formats {
                    let target = exportsDir.appendingPathComponent("\(base).\(format.fileExtension)")
                    let data = try Exporters.exporter(for: format).render(loaded.document.transcript)
                    try data.write(to: target, options: .atomic)
                }
            } catch {
                // Best-effort; primary transcription already saved.
            }
        }
    }
}
