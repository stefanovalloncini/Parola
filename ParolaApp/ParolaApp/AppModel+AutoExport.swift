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

    /// A link's audio sits in a temporary folder nobody opens, so its rules have nowhere to write.
    func noteAutoExportSkippedForLink(sourceExtension: String) {
        let planned = AutoExportEngine.plannedPresets(
            rules: autoExportRules, sourceExtension: sourceExtension, presets: exportPresets
        )
        guard !planned.isEmpty else { return }
        nonFatalWarning = String(
            localized: "Auto-export skipped this link: its rules save next to the source file, and a link has no folder to save in. Use Export instead."
        )
    }

    func runAutoExports(transcript: Transcript, sourceURL: URL) {
        writeSidecars(transcript, presets: [], source: SidecarSource(besideFile: sourceURL))
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
