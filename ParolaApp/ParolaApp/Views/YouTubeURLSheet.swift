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
                .onSubmit { submit() }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.youtubeSheetOpen = false
                    model.youtubeURLDraft = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Transcribe") { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.youtubeURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func submit() {
        let trimmed = model.youtubeURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.transcribeYouTube(urlString: trimmed)
    }
}
