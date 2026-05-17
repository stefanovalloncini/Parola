import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @EnvironmentObject var model: AppModel
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
                }
                .padding(16)
            }

            SettingsSection("Backup & restore") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Snapshot every setting on this Mac to a `.parola-settings` file, or restore one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Export settings…") {
                            SettingsExportService.presentExportPanel()
                        }
                        Button("Import settings…") {
                            SettingsExportService.presentImportPanel()
                        }
                    }
                }
                .padding(16)
            }

            SettingsSection("Reset") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clears every setting saved by Parola. Models on disk are untouched.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        resetAllConfirming = true
                    } label: {
                        Text("Reset all settings…")
                    }
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
                for scope in SettingsPaneScope.allCases {
                    SettingsResetService.reset(scope: scope)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything on every Settings pane returns to defaults.")
        }
    }
}
