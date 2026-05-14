import SwiftUI

struct YouTubeURLSheet: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribe a YouTube video")
                .font(.headline)
            Text("Paste a YouTube URL. Parola downloads the audio via yt-dlp (`brew install yt-dlp` if it's missing).")
                .foregroundStyle(.secondary)
                .font(.callout)
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
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.youtubeURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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
