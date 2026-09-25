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
                    version: model.ytDlpVersion?.text,
                    isStale: model.ytDlpIsStale,
                    updateRoute: model.ytDlpUpdateRoute,
                    installing: model.ytDlpInstalling,
                    updating: model.ytDlpUpdating,
                    error: model.ytDlpInstallError ?? model.ytDlpUpdateError,
                    isFirst: true,
                    install: { model.installYtDlpViaBrew() },
                    update: { model.updateYtDlpViaBrew() },
                    cancelUpdate: { model.cancelYtDlpUpdate() }
                )
            }
            SettingHelper(text: "Parola only uses these tools when you ask it to.")
        }
        .onAppear { model.refreshYtDlpStatus() }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let description: LocalizedStringKey
    let available: Bool
    let version: String?
    let isStale: Bool
    let updateRoute: YtDlpInstaller.UpdateRoute?
    let installing: Bool
    let updating: Bool
    let error: String?
    let isFirst: Bool
    let install: () -> Void
    let update: () -> Void
    let cancelUpdate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, DS.Spacing.medium) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(available && !isStale ? DS.Palette.success : DS.Palette.warning)
                    Text(verbatim: name).font(DS.Font.bodyStrong)
                    statusText
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf("Integrations.Text.Status.\(name)")
                    Spacer()
                    if !available {
                        installButton
                    } else if isStale, case .homebrew? = updateRoute {
                        updateButton
                        if updating {
                            Button("Cancel", action: cancelUpdate)
                                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                                .axLeaf("Integrations.Button.CancelUpdate.\(name)")
                        }
                    }
                }
                Text(description)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if available && isStale {
                    Label(
                        "This version is more than 90 days old. Downloads from YouTube and other sites may fail until you update it.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf("Integrations.Label.StaleWarning.\(name)")
                    switch updateRoute {
                    case .command(let command)?:
                        YtDlpManualUpdate(command: command, axPrefix: "Integrations")
                    case .manual?:
                        YtDlpManualUpdate(command: nil, axPrefix: "Integrations")
                    case .homebrew?, nil:
                        EmptyView()
                    }
                }
                if let error {
                    Text(error)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                        .axLeaf("Integrations.Text.Error.\(name)")
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
        }
    }

    private var statusSymbol: String {
        if !available { return "exclamationmark.circle.fill" }
        return isStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    @ViewBuilder private var statusText: some View {
        if !available {
            Text("Not installed")
        } else if let version, isStale {
            Text("\(version) — out of date")
        } else if let version {
            Text(verbatim: version)
        } else {
            Text("Installed")
        }
    }

    private var installButton: some View {
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

    private var updateButton: some View {
        Button(action: update) {
            if updating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
            } else {
                Label("Update with Homebrew", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
        .disabled(updating)
        .axLeaf("Integrations.Button.Update.\(name)")
    }
}

struct YtDlpManualUpdate: View {
    let command: String?
    let axPrefix: String

    var body: some View {
        if let command {
            commandBlock(command)
        } else {
            Text("Update yt-dlp with the tool you installed it with.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .axLeaf("\(axPrefix).Text.YtDlpUpdateManual")
        }
    }

    private func commandBlock(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Text("Update it in Terminal with this command:")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            HStack(spacing: DS.Spacing.small) {
                Text(verbatim: command)
                    .font(DS.Font.mono)
                    .textSelection(.enabled)
                    .axLeaf("\(axPrefix).Text.YtDlpUpdateCommand")
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("\(axPrefix).Button.CopyYtDlpUpdateCommand")
            }
        }
    }
}
