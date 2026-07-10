import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var resetAllConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Model storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.cacheDirectoryDisplayPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") { model.revealCacheDirectory() }
                        .axLeaf("Advanced.Button.RevealCache")
                }
                .padding(16)
            }

            SettingsSection("Backup & restore") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save the settings from every pane to a `.parola-settings` file, or restore one. Downloaded models and the prompt library are not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Export settings…") {
                            SettingsExportService.presentExportPanel()
                        }
                        .axLeaf("Advanced.Button.ExportSettings")
                        Button("Import settings…") {
                            SettingsExportService.presentImportPanel()
                        }
                        .axLeaf("Advanced.Button.ImportSettings")
                    }
                }
                .padding(16)
            }

            SettingsSection("Reset") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Returns every Settings pane to its defaults. Models on disk are untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        resetAllConfirming = true
                    } label: {
                        Text("Reset all settings…")
                    }
                    .axLeaf("Advanced.Button.ResetAll")
                }
                .padding(16)
            }
        }
        .confirmationDialog(
            "Reset every Parola setting?",
            isPresented: $resetAllConfirming,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                // reloadSettings applies the reset live; it prompts for a relaunch on its own
                // when watched folders changed, so no unconditional prompt here.
                SettingsResetService.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Settings pane returns to its defaults. Library entries, models, and dictation prompts are kept.")
        }
    }
}
