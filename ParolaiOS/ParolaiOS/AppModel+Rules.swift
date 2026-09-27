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

    /// Exports go to the library's Exports folder under the entry's title. Two entries that share a title
    /// keep their own files: the second one's are numbered, and a re-run replaces only its own.
    func runAutoExports(for entry: LibraryEntry) {
        let source = SidecarSource(
            fileExtension: (entry.manifest.originalAudioName as NSString).pathExtension,
            folder: library.libraryURL.appendingPathComponent("Exports", isDirectory: true),
            baseName: entry.title,
            owner: entry.id
        )
        let jobs = SidecarExportPlanner.plan(
            presets: [], rules: autoExportRules, library: ExportPreset.formatPresets, source: source
        )
        guard !jobs.isEmpty else { return }
        // The add cached what it saved, so this load decodes nothing.
        Task.detached(priority: .utility) { [library] in
            do {
                let loaded = try await library.load(entry.id)
                _ = await ExportRunner.run(jobs, transcript: loaded.document.transcript)
            } catch {
                ParolaLog.error(.export, "auto-export could not start", [.error: .error(error)])
            }
        }
    }
}
