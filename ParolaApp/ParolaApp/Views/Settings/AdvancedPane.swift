import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var resetAllConfirming = false
    @State private var transferFailure: SettingsTransferFailure?

    var body: some View {
        SettingsForm {
            SettingsSection("Backup & restore") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save your settings to a `.parola-settings` file, or restore one. Downloaded models and the prompt library are not included.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                    HStack(spacing: 8) {
                        Button("Export Settings…") {
                            transferFailure = SettingsExportService.presentExportPanel()
                        }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Advanced.Button.ExportSettings")
                        Button("Import Settings…") {
                            transferFailure = SettingsExportService.presentImportPanel()
                        }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DiagnosticsSection()

            SettingsSection("Reset") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Returns every setting to its default. Models on disk are untouched.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                    Button(role: .destructive) {
                        resetAllConfirming = true
                    } label: {
                        Text("Reset all settings…")
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Advanced.Button.ResetAll")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
