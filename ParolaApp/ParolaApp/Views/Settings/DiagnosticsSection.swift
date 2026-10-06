import SwiftUI
import AppKit
import ParolaCore

struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    var directory: URL = AppModel.diagnosticsDirectory
    @State private var hasDiagnostics = false
    @State private var diagnosticsFailure: String?

    var body: some View {
        SettingsSection("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kept for 7 days, up to 10 MB. No transcript text, file names, or paths.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("Advanced.Text.DiagnosticsRetention")
                HStack(spacing: 8) {
                    Button("Export…") { exportDiagnostics() }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Advanced.Button.ExportDiagnostics")
                    Button("Reveal in Finder") {
                        Task { await model.revealDiagnostics(directory: directory) }
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Advanced.Button.RevealDiagnostics")
                    Button("Delete Diagnostics", role: .destructive) {
                        Task {
                            await model.deleteDiagnostics(directory: directory)
                            hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
                        }
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Advanced.Button.DeleteDiagnostics")
                    .disabled(!hasDiagnostics)
                }
                .alert(
                    Text("Couldn't export diagnostics"),
                    isPresented: Binding(
                        get: { diagnosticsFailure != nil },
                        set: { if !$0 { diagnosticsFailure = nil } }
                    ),
                    presenting: diagnosticsFailure
                ) { _ in
                    Button("OK") {}
                } message: { message in
                    Text(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.medium)
        }
        .task {
            hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
            }
        }
    }

    private func exportDiagnostics() {
        Task {
            do {
                try await model.exportDiagnostics(directory: directory)
            } catch {
                diagnosticsFailure = error.localizedDescription
            }
            hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
        }
    }
}
