import SwiftUI
import ParolaCore

struct YouTubeURLSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Transcribe a YouTube video")
                .font(DS.Font.heading)
            Text("Paste a URL — Parola downloads the audio locally with yt-dlp.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !model.ytDlpAvailable {
                YtDlpBanner()
            }

            TextField("https://www.youtube.com/watch?v=…", text: $urlDraft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit(prefersExistingSubs: false) }

            HStack(spacing: DS.Spacing.small) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Captions") { submit(prefersExistingSubs: true) }
                    .disabled(disabled || !model.ytDlpAvailable)
                Button("Transcribe") { submit(prefersExistingSubs: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled || !model.ytDlpAvailable)
            }
        }
        .padding(DS.Spacing.large)
        .frame(width: 520)
        .onAppear {
            model.refreshYtDlpAvailability()
            if urlDraft.isEmpty,
               let clipboard = NSPasteboard.general.string(forType: .string),
               let url = URL(string: clipboard.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.isYouTubeVideo {
                urlDraft = url.absoluteString
            }
            fieldFocused = true
        }
    }

    private var disabled: Bool {
        urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(prefersExistingSubs: Bool) {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if prefersExistingSubs {
            model.fetchYouTubeSubs(urlString: trimmed)
        } else {
            model.transcribeYouTube(urlString: trimmed)
        }
    }
}

private struct YtDlpBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .top, spacing: DS.Spacing.small) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("yt-dlp isn't installed")
                        .font(DS.Font.heading)
                    Text("Parola uses yt-dlp to fetch YouTube audio locally. Install it once and you're set.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let error = model.ytDlpInstallError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Spacing.small) {
                Button {
                    model.installYtDlpViaBrew()
                } label: {
                    if model.ytDlpInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Label("Install with Homebrew", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.ytDlpInstalling)

                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                }
                .disabled(model.ytDlpInstalling)
            }
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
    }
}
