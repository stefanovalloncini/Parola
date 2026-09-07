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
    // Cached so `transcript.text` (a full-segment join) isn't rebuilt on every header re-render;
    // only recomputed when the transcript actually changes or the title changes.
    @State private var shareItem: TranscriptShareFile?

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.heading)
                .lineLimit(1)
                .truncationMode(.middle)

            if let label = languageLabel {
                Text(label)
                    .font(DS.Font.caption2Emphasized)
                    .foregroundStyle(DS.Color.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Color.accentWash))
                    .modifier(LanguagePillHelpModifier(isAssumed: model.assumedLanguageNotice != nil))
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

            Button { model.transcriptCompact.toggle() } label: {
                Image(systemName: model.transcriptCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .modifier(CompactHelpModifier(isCompact: model.transcriptCompact))
            .axLeaf("HeaderBar.Button.ToggleCompact")

            if model.features.isEnabled(.ai) {
                groupDivider

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

                PromptsMenu()
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(model.isRunningPrompt)
            }

            groupDivider

            Button { toggleSpeak() } label: {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .modifier(SpeakHelpModifier(isSpeaking: speaker.isSpeaking))
            .axLeaf("HeaderBar.Button.Speak")

            Button(action: copyTranscript) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.transcript == nil)
            .help("Copy transcript")
            .accessibilityLabel("Copy transcript")
            .axLeaf("HeaderBar.Button.CopyTranscript")

            if let shareItem {
                ShareLink(item: shareItem, preview: SharePreview(title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Share transcript")
                .accessibilityLabel("Share transcript")
                .axLeaf("HeaderBar.Button.Share")
            }

            Button(action: onAdvance) {
                Image(systemName: "chevron.right.2")
                    .font(DS.Font.heading)
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
        .onAppear { rebuildShareItem() }
        .onChange(of: model.transcriptVersion) { _, _ in rebuildShareItem() }
        .onChange(of: title) { _, _ in rebuildShareItem() }
    }

    private var groupDivider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 2)
    }

    private func rebuildShareItem() {
        guard model.transcript != nil else { shareItem = nil; return }
        shareItem = TranscriptShareFile(title: title, text: model.transcriptText)
    }

    private func copyTranscript() {
        guard let segments = model.transcript?.segments else { return }
        let labelled = model.transcriptSpeakers.count >= 2
        guard segments.count > TranscriptDerive.synchronousCap else {
            writeToPasteboard(TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: labelled))
            return
        }
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: labelled)
            }.value
            writeToPasteboard(text)
        }
    }

    private func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func toggleSpeak() {
        if speaker.isSpeaking {
            speaker.stop()
        } else if model.transcript != nil {
            speaker.speak(model.transcriptText, languageCode: model.transcript?.language)
        }
    }

    private var languageLabel: String? {
        LanguageDisplay.code(for: model.transcript?.language)
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
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
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

private struct LanguagePillHelpModifier: ViewModifier {
    let isAssumed: Bool
    func body(content: Content) -> some View {
        content.help(isAssumed ? "Assumed language" : "Detected language")
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
