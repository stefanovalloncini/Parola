import SwiftUI

struct YouTubeURLSheet: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Transcribe a YouTube video")
                .font(DS.Font.heading)
            Text("Paste a URL. Parola downloads the audio with yt-dlp (run `brew install yt-dlp` if it's missing).")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://www.youtube.com/watch?v=…", text: $model.youtubeURLDraft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit(prefersExistingSubs: false) }

            HStack(spacing: DS.Spacing.small) {
                Button("Cancel") {
                    model.youtubeSheetOpen = false
                    model.youtubeURLDraft = ""
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Captions") {
                    submit(prefersExistingSubs: true)
                }
                .disabled(disabled)
                Button("Transcribe") {
                    submit(prefersExistingSubs: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
            }
        }
        .padding(DS.Spacing.large)
        .frame(width: 480)
        .onAppear {
            if model.youtubeURLDraft.isEmpty, let clipboard = NSPasteboard.general.string(forType: .string),
               clipboard.hasPrefix("http"), clipboard.count < 200 {
                model.youtubeURLDraft = clipboard
            }
            fieldFocused = true
        }
    }

    private var disabled: Bool {
        model.youtubeURLDraft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
    }

    private func submit(prefersExistingSubs: Bool) {
        let trimmed = model.youtubeURLDraft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if prefersExistingSubs {
            model.fetchYouTubeSubs(urlString: trimmed)
        } else {
            model.transcribeYouTube(urlString: trimmed)
        }
    }
}
