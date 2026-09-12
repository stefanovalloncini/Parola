import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var resetAllConfirming = false
    @State private var transferFailure: SettingsTransferFailure?

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
                    Text("Save your settings to a `.parola-settings` file, or restore one. Downloaded models and the prompt library are not included.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Export Settings…") {
                            transferFailure = SettingsExportService.presentExportPanel()
                        }
                        .axLeaf("Advanced.Button.ExportSettings")
                        Button("Import Settings…") {
                            transferFailure = SettingsExportService.presentImportPanel()
                        }
                        .axLeaf("Advanced.Button.ImportSettings")
                    }
                    .alert(
                        transferFailure?.operation == .export ? Text("Couldn't export settings") : Text("Couldn't import settings"),
                        isPresented: Binding(
                            get: { transferFailure != nil },
                            set: { if !$0 { transferFailure = nil } }
                        ),
                        presenting: transferFailure
                    ) { _ in
                        Button("OK") {}
                    } message: { failure in
                        Text(failure.message)
                    }
                }
                .padding(16)
            }

            SettingsSection("Reset") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Returns every setting to its default. Models on disk are untouched.")
                        .font(DS.Font.secondary)
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
            Text("Every Settings pane returns to its defaults, including your correction, find & replace, ignored-segment, snippet, and auto-export rules. Library entries, models, and custom prompts are kept.")
        }
    }
}
