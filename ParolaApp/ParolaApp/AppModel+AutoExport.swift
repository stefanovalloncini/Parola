import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadAutoExportRules() {
        guard let data = UserDefaults.standard.data(forKey: "autoExportRules"),
              let rules = try? JSONDecoder().decode([AutoExportRule].self, from: data) else { return }
        autoExportRules = rules
    }

    func saveAutoExportRules() {
        if let data = try? JSONEncoder().encode(autoExportRules) {
            UserDefaults.standard.set(data, forKey: "autoExportRules")
        }
    }

    func runAutoExports(transcript: Transcript, sourceURL: URL) {
        let formats = AutoExportEngine.plannedFormats(
            rules: autoExportRules,
            sourceExtension: sourceURL.pathExtension
        )
        for format in formats {
            do {
                let target = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
                let data = try Exporters.exporter(for: format).render(transcript)
                try data.write(to: target, options: .atomic)
            } catch {
                // Auto-export is best-effort; primary transcription already in the library.
            }
        }
    }
}
