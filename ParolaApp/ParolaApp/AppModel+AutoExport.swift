import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadAutoExportRules() {
        autoExportRules = readJSON([AutoExportRule].self, forKey: "autoExportRules") ?? []
    }

    func saveAutoExportRules() {
        writeJSON(autoExportRules, forKey: "autoExportRules")
    }

    func runAutoExports(transcript: Transcript, sourceURL: URL, skippingTargets: Set<URL> = []) {
        let formats = AutoExportEngine.plannedFormats(
            rules: autoExportRules,
            sourceExtension: sourceURL.pathExtension
        )
        guard !formats.isEmpty else { return }
        let specs = formats.map { exportSpec(for: $0) }
        Task.detached(priority: .utility) {
            for spec in specs {
                do {
                    let target = sourceURL.deletingPathExtension().appendingPathExtension(spec.format.fileExtension)
                    guard !skippingTargets.contains(target) else { continue }
                    let data = try Exporters.exporter(for: spec).render(transcript)
                    try data.write(to: target, options: .atomic)
                } catch {
                    // Auto-export is best-effort; primary transcription already in the library.
                    ParolaLog.error(.export, "auto-export failed as \(spec.format)", [.error: .error(error)])
                }
            }
        }
    }
}
