import SwiftUI

struct TranscriptHeaderBar: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var speaker = TranscriptSpeaker()
    let title: String
    let onAdvance: () -> Void
    let onOpenSummary: () -> Void
    let onOpenChat: () -> Void

    @State private var outlineOpen = false

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.heading)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { outlineOpen.toggle() } label: {
                Image(systemName: "list.bullet.rectangle.portrait")
            }
            .buttonStyle(.borderless)
            .help("Outline")
            .popover(isPresented: $outlineOpen, arrowEdge: .bottom) {
                OutlinePopover { seconds in
                    model.seekTo(seconds: seconds)
                    outlineOpen = false
                }
                .environmentObject(model)
            }

            Button { toggleSpeak() } label: {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(speaker.isSpeaking ? "Stop reading" : "Read aloud")

            Button { model.transcriptCompact.toggle() } label: {
                Image(systemName: model.transcriptCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help(model.transcriptCompact ? "Expanded view" : "Compact view")

            Button(action: onOpenSummary) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Summary")

            Button(action: onOpenChat) {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Chat with this transcript")

            Button(action: onAdvance) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Color.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .help("Jump to next segment")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    private func toggleSpeak() {
        if speaker.isSpeaking {
            speaker.stop()
        } else if let text = model.transcript?.text {
            speaker.speak(text, languageCode: model.transcript?.language)
        }
    }
}
