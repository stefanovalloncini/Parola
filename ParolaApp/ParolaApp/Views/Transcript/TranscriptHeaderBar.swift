import SwiftUI
import ParolaCore

struct TranscriptHeaderBar: View {
    @Environment(AppModel.self) private var model
    @State private var speaker = TranscriptSpeaker()
    let title: String
    let onAdvance: () -> Void
    let onOpenSummary: () -> Void
    let onOpenChat: () -> Void

    @State private var outlineOpen = false
    @State private var jumpOpen = false
    @State private var jumpDraft = ""

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.heading)
                .lineLimit(1)
                .truncationMode(.middle)

            if let label = languageLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Color.accent.opacity(0.14)))
                    .help("Detected language")
            }

            Spacer()

            Button { outlineOpen.toggle() } label: {
                Image(systemName: "list.bullet.rectangle.portrait")
            }
            .buttonStyle(.borderless)
            .help("Outline")
            .accessibilityLabel("Outline")
            .popover(isPresented: $outlineOpen, arrowEdge: .bottom) {
                OutlinePopover { seconds in
                    model.seekTo(seconds: seconds)
                    outlineOpen = false
                }
                .environment(model)
            }
            .axLeaf("HeaderBar.Button.Outline")

            Button { jumpOpen.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Jump to time")
            .accessibilityLabel("Jump to time")
            .popover(isPresented: $jumpOpen, arrowEdge: .bottom) {
                jumpPopover
            }
            .axLeaf("HeaderBar.Button.JumpToTime")

            Button { toggleSpeak() } label: {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .modifier(SpeakHelpModifier(isSpeaking: speaker.isSpeaking))
            .axLeaf("HeaderBar.Button.Speak")

            Button { model.transcriptCompact.toggle() } label: {
                Image(systemName: model.transcriptCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .modifier(CompactHelpModifier(isCompact: model.transcriptCompact))
            .axLeaf("HeaderBar.Button.ToggleCompact")

            Button(action: onOpenSummary) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Summary")
            .accessibilityLabel("Summary")
            .axLeaf("HeaderBar.Button.OpenSummary")

            Button(action: onOpenChat) {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Chat with this transcript")
            .accessibilityLabel("Chat with this transcript")
            .axLeaf("HeaderBar.Button.OpenChat")

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
            .accessibilityLabel("Jump to next segment")
            .axLeaf("HeaderBar.Button.Advance")
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

    private var languageLabel: String? {
        guard let code = model.transcript?.language, !code.isEmpty else { return nil }
        return code.uppercased()
    }

    private var jumpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jump to time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("mm:ss", text: $jumpDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { commitJump() }
                    .axLeaf("HeaderBar.TextField.JumpTime")
                Button("Go", action: commitJump)
                    .buttonStyle(.borderedProminent)
                    .disabled(Timecode.parse(jumpDraft) == nil)
                    .axLeaf("HeaderBar.Button.JumpGo")
            }
        }
        .padding(12)
    }

    private func commitJump() {
        guard let seconds = Timecode.parse(jumpDraft) else { return }
        model.seekTo(seconds: seconds)
        jumpDraft = ""
        jumpOpen = false
    }
}

private struct SpeakHelpModifier: ViewModifier {
    let isSpeaking: Bool
    func body(content: Content) -> some View {
        let text = isSpeaking ? "Stop reading" : "Read aloud"
        content.help(text).accessibilityLabel(text)
    }
}

private struct CompactHelpModifier: ViewModifier {
    let isCompact: Bool
    func body(content: Content) -> some View {
        let text = isCompact ? "Expanded view" : "Compact view"
        content.help(text).accessibilityLabel(text)
    }
}
