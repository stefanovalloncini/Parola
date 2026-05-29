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
                    Text("Snapshot every setting on this Mac to a `.parola-settings` file, or restore one.")
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
                    Text("Clears every setting saved by Parola. Models on disk are untouched.")
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
                SettingsResetService.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything on every Settings pane returns to defaults.")
        }
    }
}
