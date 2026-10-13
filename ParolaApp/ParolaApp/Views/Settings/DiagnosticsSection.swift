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
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Export…") { exportDiagnostics() }
                        .accessibilityLabel("Export Diagnostics…")
                        .axLeaf("Advanced.Button.ExportDiagnostics")
                    Button("Reveal in Finder") {
                        Task { await model.revealDiagnostics(directory: directory) }
                    }
                    .axLeaf("Advanced.Button.RevealDiagnostics")
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.deleteDiagnostics(directory: directory)
                            hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
                        }
                    }
                    .accessibilityLabel("Delete Diagnostics")
                    .axLeaf("Advanced.Button.DeleteDiagnostics")
                    .disabled(!hasDiagnostics)
                }
            } label: {
                Text("Diagnostics log")
                Text("Kept for 7 days, up to 10 MB. No transcript text, file names, or paths.")
                    .axLeaf("Advanced.Text.DiagnosticsRetention")
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
                diagnosticsFailure = FailureText.message(for: error)
            }
            hasDiagnostics = await model.diagnosticsRecordsExist(directory: directory)
        }
    }
}
