import SwiftUI
import ParolaCore

struct YouTubeURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SheetFrame(
            icon: "play.rectangle.fill",
            iconTint: DS.Color.accent,
            title: "Add video URL",
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
        .onAppear {
            model.youtubeURLError = nil
            model.refreshYtDlpAvailability()
            if urlDraft.isEmpty,
               let clipboard = NSPasteboard.general.string(forType: .string),
               let url = URL(string: clipboard.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.isYtDlpSupported {
                urlDraft = url.absoluteString
            }
            fieldFocused = true
        }
    }

    private var contentBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Text("Paste a link from YouTube, Vimeo, X, TikTok, SoundCloud, or any yt-dlp source. Parola downloads the audio locally.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("https://www.youtube.com/watch?v=…", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { submit(prefersExistingSubs: false) }
                    .onChange(of: urlDraft) { _, _ in model.youtubeURLError = nil }
                    .axLeaf("YouTube.TextField.URL")

                if let error = model.youtubeURLError {
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .axLeaf("YouTube.Text.URLError")
                }

                if !model.ytDlpAvailable {
                    YtDlpBanner()
                }
            }
            .padding(DS.Spacing.regular)
        }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Cancel") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("YouTube.Button.Cancel")

            Spacer()

            Button("Use captions") { submit(prefersExistingSubs: true) }
                .sheetSecondaryAction()
                .disabled(disabled || !model.ytDlpAvailable)
                .axLeaf("YouTube.Button.UseCaptions")

            Button("Transcribe") { submit(prefersExistingSubs: false) }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || !model.ytDlpAvailable)
                .axLeaf("YouTube.Button.Transcribe")
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
    @Environment(AppModel.self) private var model

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
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                .disabled(model.ytDlpInstalling)
                .axLeaf("YouTube.Button.InstallYtDlp")

                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                }
                .disabled(model.ytDlpInstalling)
                .axLeaf("YouTube.Button.CopyBrewCommand")
            }
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
    }
}
