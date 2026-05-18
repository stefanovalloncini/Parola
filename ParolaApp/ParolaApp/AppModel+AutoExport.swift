import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadAutoExportRules() {
        if let rules = AppModel.readJSON([AutoExportRule].self, forKey: "autoExportRules") {
            autoExportRules = rules
        }
    }

    func saveAutoExportRules() {
        AppModel.writeJSON(autoExportRules, forKey: "autoExportRules")
    }

    func runAutoExports(transcript: Transcript, sourceURL: URL) {
        let formats = AutoExportEngine.plannedFormats(
            rules: autoExportRules,
            sourceExtension: sourceURL.pathExtension
        )
        guard !formats.isEmpty else { return }
        Task.detached(priority: .utility) {
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
}
