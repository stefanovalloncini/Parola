import SwiftUI
import ParolaCore
import AppKit

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var copiedVersion = false
    @State private var hasDiagnostics = false
    @State private var diagnosticsFailure: String?

    var body: some View {
        VStack(spacing: 16) {
            AboutInfoView()
                .padding(.top, 8)

            HStack(spacing: 10) {
                Button("Open Repository") {
                    NSWorkspace.shared.open(SupportLinks.repository)
                }
                .axLeaf("About.Button.OpenRepository")
                Button(copiedVersion ? "Copied" : "Copy Version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Parola \(AboutInfo.versionString)", forType: .string)
                    copiedVersion = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedVersion = false
                    }
                }
                .axLeaf("About.Button.CopyVersion")
            }
            .controlSize(.small)

            if ManagedConfiguration.shared.isActive {
                Text("Some features are managed by your deployment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .axLeaf("About.Text.ManagedNote")
            }

            SettingsSection("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kept for 7 days, up to 10 MB. No transcript text, file names, or paths.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(.secondary)
                        .axLeaf("About.Text.DiagnosticsRetention")
                    HStack(spacing: 8) {
                        Button("Export…") { exportDiagnostics() }
                            .axLeaf("About.Button.ExportDiagnostics")
                        Button("Reveal in Finder") {
                            Task { await model.revealDiagnostics() }
                        }
                        .axLeaf("About.Button.RevealDiagnostics")
                        Button("Delete Diagnostics", role: .destructive) {
                            Task {
                                await model.deleteDiagnostics()
                                hasDiagnostics = await model.diagnosticsRecordsExist()
                            }
                        }
                        .axLeaf("About.Button.DeleteDiagnostics")
                        .disabled(!hasDiagnostics)
                    }
                    .controlSize(.small)
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
                .padding(16)
            }
            .task {
                hasDiagnostics = await model.diagnosticsRecordsExist()
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    hasDiagnostics = await model.diagnosticsRecordsExist()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func exportDiagnostics() {
        Task {
            do {
                try await model.exportDiagnostics()
            } catch {
                diagnosticsFailure = error.localizedDescription
            }
            hasDiagnostics = await model.diagnosticsRecordsExist()
        }
    }
}
