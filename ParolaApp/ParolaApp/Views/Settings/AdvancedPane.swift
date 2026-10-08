import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var resetAllConfirming = false
    @State private var transferFailure: SettingsTransferFailure?

    var body: some View {
        SettingsForm {
            SettingsSection("Backup & restore") {
                SettingRow("Settings file",
                           description: "Save your settings to a `.parola-settings` file, or restore one. Downloaded models and the prompt library are not included.") {
                    HStack(spacing: 8) {
                        Button("Export…") {
                            transferFailure = SettingsExportService.presentExportPanel()
                        }
                        .accessibilityLabel("Export Settings…")
                        .axLeaf("Advanced.Button.ExportSettings")
                        Button("Import…") {
                            transferFailure = SettingsExportService.presentImportPanel()
                        }
                        .accessibilityLabel("Import Settings…")
                        .axLeaf("Advanced.Button.ImportSettings")
                    }
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

            DiagnosticsSection()

            SettingsSection("Reset") {
                SettingRow("All settings",
                           description: "Returns every setting to its default. Models on disk are untouched.") {
                    Button("Reset all settings…", role: .destructive) {
                        resetAllConfirming = true
                    }
                    .axLeaf("Advanced.Button.ResetAll")
                }
            }
        }
        .confirmationDialog(
            "Reset every Parola setting?",
            isPresented: $resetAllConfirming,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                model.forgetAIServiceKeys()
                SettingsResetService.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: Self.resetAllMessage())
        }
    }

    nonisolated static func resetAllMessage(bundle: Bundle = .main) -> String {
        String(
            localized: "Every Settings pane returns to its defaults. This also deletes your watched folders, rules, snippets, export presets, Send To destinations, per-app dictation settings, and AI services with their API keys. Library entries, models, and custom prompts are kept.",
            bundle: bundle
        )
    }
}
