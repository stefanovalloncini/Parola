import SwiftUI
import ParolaCore
import AppKit

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var copiedVersion = false
    @State private var hasDiagnostics = false

    var body: some View {
        VStack(spacing: 16) {
            AboutInfoView()
                .padding(.top, 8)

            HStack(spacing: 10) {
                Button("Open repository") {
                    NSWorkspace.shared.open(SupportLinks.repository)
                }
                .axLeaf("About.Button.OpenRepository")
                Button(copiedVersion ? "Copied" : "Copy version") {
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
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .axLeaf("About.Text.DiagnosticsRetention")
                    HStack(spacing: 8) {
                        Button("Export…") {
                            Task { await model.exportDiagnostics() }
                        }
                        .axLeaf("About.Button.ExportDiagnostics")
                        Button("Reveal in Finder") {
                            model.revealDiagnostics()
                        }
                        .axLeaf("About.Button.RevealDiagnostics")
                        Button("Delete Diagnostics") {
                            Task {
                                await model.deleteDiagnostics()
                                hasDiagnostics = model.diagnosticsRecordsExist()
                            }
                        }
                        .axLeaf("About.Button.DeleteDiagnostics")
                        .disabled(!hasDiagnostics)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .onAppear { hasDiagnostics = model.diagnosticsRecordsExist() }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
