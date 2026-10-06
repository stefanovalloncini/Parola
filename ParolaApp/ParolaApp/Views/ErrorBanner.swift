import SwiftUI

/// A card the route keeps behind: a failed run shouldn't cost the user the library.
struct ErrorBanner: View {
    let message: String
    /// A failed take on its Stage: Retry, Reveal in Finder and Dismiss act on the take, and nothing a file or link run left behind shows.
    var take: RecordingSession?
    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?

    private var canRetry: Bool {
        guard let take else { return model?.canRetryFailedTranscription == true }
        return take.failure != nil
    }

    private var failedName: String? {
        guard let take else { return model?.failedSourceName }
        return take.failure?.title
    }

    var body: some View {
        let offer = take == nil ? model?.ytDlpUpdateOffer ?? .none : .none
        let updateLeads = offer == .update || offer == .updating
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.danger)
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                title
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(2)
                Text(AppModel.errorDetail(from: message))
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(AppModel.errorDetail(from: message))
                ytDlpStatus(offer)
                HStack(spacing: DS.Spacing.small) {
                    if updateLeads {
                        updateButton(updating: offer == .updating)
                    }
                    if let permission = take?.missingPermission {
                        Button("Open System Settings…") { Self.openSettings(for: permission) }
                            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                            .axLeaf("Error.Button.OpenSystemSettings")
                    }
                    if canRetry {
                        Button("Retry") { retry() }
                            .buttonStyle(DSPillButtonStyle(kind: updateLeads ? .secondary : .primary, size: .compact))
                            .disabled(offer == .updating)
                            .axLeaf("Error.Button.Retry")
                    }
                    if revealsInFinder {
                        Button("Reveal in Finder") { reveal() }
                            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                            .axLeaf("Error.Button.RevealInFinder")
                    }
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Error.Button.Dismiss")
                }
                .padding(.top, DS.Spacing.small)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.regular)
        // Without a width floor the message wraps per character when asked for its ideal size, and the route's height explodes.
        .frame(minWidth: MainWindowLayout.narrowestPaneWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Color.danger.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder private func ytDlpStatus(_ offer: AppModel.YtDlpUpdateOffer) -> some View {
        switch offer {
        case .updated(let version):
            Label {
                Text("Updated yt-dlp to \(version).")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
            .axLeaf("Error.Label.YtDlpUpdated")
        case .command(let command):
            YtDlpManualUpdate(command: command, axPrefix: "Error")
        case .manual:
            YtDlpManualUpdate(command: nil, axPrefix: "Error")
        case .update:
            if let error = model?.ytDlpUpdateError {
                Text(error)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.dangerText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(error)
                    .axLeaf("Error.Text.YtDlpUpdateError")
            }
        case .none, .updating:
            EmptyView()
        }
    }

    private func updateButton(updating: Bool) -> some View {
        Button { model?.updateYtDlpViaBrew() } label: {
            if updating {
                HStack(spacing: DS.Spacing.snug) {
                    ProgressView().controlSize(.small)
                    Text("Updating yt-dlp…")
                }
            } else {
                Label("Update yt-dlp", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
        .disabled(updating)
        .axLeaf("Error.Button.UpdateYtDlp")
    }

    /// A failed take is in the library once its failure saved it, and Finder can point at its entry.
    nonisolated static func revealsTakeInFinder(_ take: RecordingSession) -> Bool {
        take.failure?.save != nil
    }

    private var revealsInFinder: Bool {
        guard let take else { return model?.failedFileURL != nil }
        return Self.revealsTakeInFinder(take)
    }

    private func reveal() {
        if take == nil { model?.revealFailedFile() } else { model?.revealFailedTake() }
    }

    private var title: Text {
        if let take, let failed = Self.takeTitle(failedWhile: take.failedWhile) { return Text(verbatim: failed) }
        guard let name = failedName, !name.isEmpty else { return Text("Something went wrong") }
        return Text("Couldn't transcribe \(name)")
    }

    /// A take that failed before its transcription began says what went wrong with the recording itself.
    nonisolated static func takeTitle(failedWhile: RecordingSession.FailedWhile?, bundle: Bundle = .main) -> String? {
        switch failedWhile {
        case .starting: String(localized: "Couldn't start the recording", bundle: bundle)
        case .recording: String(localized: "The recording stopped", bundle: bundle)
        case .transcribing, nil: nil
        }
    }

    private static func openSettings(for permission: RecordingSession.Permission) {
        switch permission {
        case .microphone: openMicrophonePrivacySettings()
        case .screenRecording: SystemCapturePermissions.openSystemSettings(pane: "Privacy_ScreenCapture")
        }
    }

    private func retry() {
        if take == nil { model?.retryFailedTranscription() } else { model?.retryFailedTake() }
    }

    private func dismiss() {
        if take == nil { model?.dismissError() } else { model?.dismissTakeFailure() }
    }
}
