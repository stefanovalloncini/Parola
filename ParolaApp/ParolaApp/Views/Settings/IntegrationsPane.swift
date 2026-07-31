import SwiftUI
import ParolaCore

struct IntegrationsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                ToolStatusRow(
                    name: "yt-dlp",
                    description: "Required to transcribe YouTube and other video links. Audio downloads locally; no upload happens.",
                    available: model.ytDlpAvailable,
                    installing: model.ytDlpInstalling,
                    error: model.ytDlpInstallError,
                    isFirst: true,
                    install: { model.installYtDlpViaBrew() }
                )
            }
            SettingHelper(text: "Parola only uses these tools when you ask it to.")
        }
        .onAppear { model.refreshYtDlpAvailability() }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let description: LocalizedStringKey
    let available: Bool
    let installing: Bool
    let error: String?
    let isFirst: Bool
    let install: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(available ? Color.green : Color.orange)
                    Text(verbatim: name).font(.body.weight(.semibold))
                    Text(available ? "Installed" : "Not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !available {
                        Button(action: install) {
                            if installing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Installing…")
                                }
                            } else {
                                Label("Install with Homebrew", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                        .disabled(installing)
                        .axLeaf("Integrations.Button.Install.\(name)")
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DS.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
