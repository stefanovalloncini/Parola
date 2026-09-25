import SwiftUI
import ParolaCore

struct TranscriptHeaderBar: View {
    @Environment(AppModel.self) private var model
    @State private var speaker = TranscriptSpeaker()
    let title: String
    let onAdvance: () -> Void

    @State private var outlineOpen = false
    @State private var jumpOpen = false
    @State private var jumpDraft = ""
    @FocusState private var jumpFocused: Bool
    // Cached so the header doesn't rebuild `transcript.text`, a full-segment join, on every re-render.
    @State private var shareItem: TranscriptShareFile?

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            if model.canReturnToOrigin {
                TranscriptBackLink()
            }

            Text(title)
                .font(DS.Font.heading)
                .lineLimit(1)
                .truncationMode(.middle)

            if let label = languageLabel {
                Text(label)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accentText)
                    .padding(.horizontal, DS.Spacing.snug)
                    .padding(.vertical, DS.Spacing.hair)
                    .background(Capsule().fill(DS.Color.accentWash))
                    .modifier(LanguagePillHelpModifier(isAssumed: model.assumedLanguageNotice != nil))
            }

            Spacer()

            controls
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .onAppear { rebuildShareItem() }
        .onChange(of: model.transcriptVersion) { _, _ in rebuildShareItem() }
        .onChange(of: title) { _, _ in rebuildShareItem() }
    }

    private var controls: some View {
        HStack(spacing: controlGap) {
            glyphGroup {
                outlineButton
                jumpButton
                compactButton
            }

            if model.features.isEnabled(.ai) {
                groupDivider
                paneModePicker
                aiMenu
            }

            groupDivider

            glyphGroup {
                speakButton
                copyButton
                shareButton
            }

            if model.features.isEnabled(.ai) {
                groupDivider
                PromptsMenu()
                    .menuStyle(.button)
                    .buttonStyle(GlyphButtonStyle(tinted: true))
                    .fixedSize()
                    .disabled(model.isRunningPrompt)
            }

            advanceButton
        }
    }

    /// Gaps that keep the 24 pt targets on the glyphs' 24 pt pitch.
    private var controlGap: CGFloat {
        model.features.isEnabled(.ai) ? DS.Spacing.snug : DS.Spacing.tight
    }

    /// The targets reach a point into the bar's padding, so without the 24 pt AI picker the row keeps its 22 pt height.
    private func glyphGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .padding(.vertical, -1)
    }

    private var outlineButton: some View {
        Button { outlineOpen.toggle() } label: {
            Image(systemName: "list.bullet.rectangle.portrait")
        }
        .buttonStyle(GlyphButtonStyle(tinted: true))
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
    }

    private var jumpButton: some View {
        Button { jumpOpen.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .buttonStyle(GlyphButtonStyle(tinted: true))
        .help("Jump to time")
        .accessibilityLabel("Jump to time")
        .popover(isPresented: $jumpOpen, arrowEdge: .bottom) {
            jumpPopover
        }
        .axLeaf("HeaderBar.Button.JumpToTime")
    }

    private var compactButton: some View {
        Button { model.transcriptCompact.toggle() } label: {
            Image(systemName: model.transcriptCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(GlyphButtonStyle(tinted: true))
        .modifier(CompactHelpModifier(isCompact: model.transcriptCompact))
        .axLeaf("HeaderBar.Button.ToggleCompact")
    }

    private var speakButton: some View {
        Button { toggleSpeak() } label: {
            Image(systemName: speaker.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .buttonStyle(GlyphButtonStyle(tinted: true))
        .modifier(SpeakHelpModifier(isSpeaking: speaker.isSpeaking))
        .axLeaf("HeaderBar.Button.Speak")
    }

    private var copyButton: some View {
        Button(action: copyTranscript) {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(GlyphButtonStyle(tinted: true))
        .disabled(model.transcript == nil)
        .help("Copy transcript")
        .accessibilityLabel("Copy transcript")
        .axLeaf("HeaderBar.Button.CopyTranscript")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareItem {
            ShareLink(item: shareItem, preview: SharePreview(title)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(GlyphButtonStyle(tinted: true))
            .help("Share transcript")
            .accessibilityLabel("Share transcript")
            .axLeaf("HeaderBar.Button.Share")
        }
    }

    private var advanceButton: some View {
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

    private var paneModePicker: some View {
        Picker(selection: paneModeBinding) {
            ForEach(availablePaneModes, id: \.self) { mode in
                Label(Self.paneModeLabel(mode), systemImage: Self.paneModeSymbol(mode)).tag(mode)
            }
        } label: {
            Label(Self.paneModeLabel(model.transcriptPaneMode), systemImage: Self.paneModeSymbol(model.transcriptPaneMode))
        }
        .labelsHidden()
        .labelStyle(.titleAndIcon)
        .pickerStyle(.menu)
        .fixedSize()
        .help("Switch between Transcript, Summary and Chat")
        .axLeaf("HeaderBar.Picker.PaneMode")
    }

    /// Rows a menu Picker can't disable per-item, so an unreachable mode (no transcript, or AI off) is left out instead.
    private var availablePaneModes: [AppModel.TranscriptPaneMode] {
        AppModel.TranscriptPaneMode.allCases.filter { model.canShow($0) }
    }

    private var paneModeBinding: Binding<AppModel.TranscriptPaneMode> {
        Binding(
            get: { model.transcriptPaneMode },
            set: { model.setTranscriptPaneMode($0) }
        )
    }

    static func paneModeLabel(_ mode: AppModel.TranscriptPaneMode) -> String {
        switch mode {
        case .transcript: return String(localized: "Transcript")
        case .summary: return String(localized: "Summary")
        case .chat: return String(localized: "Chat")
        }
    }

    static func paneModeSymbol(_ mode: AppModel.TranscriptPaneMode) -> String {
        switch mode {
        case .transcript: return "text.alignleft"
        case .summary: return "sparkles.rectangle.stack"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    private var aiMenu: some View {
        Menu {
            Button("Summary") { model.setTranscriptPaneMode(.summary) }
                .accessibilityIdentifier("ai.summary")
                .axLeaf("HeaderBar.Button.OpenSummary")
            Button("Chat") { model.setTranscriptPaneMode(.chat) }
                .accessibilityIdentifier("ai.chat")
                .axLeaf("HeaderBar.Button.OpenChat")
            Divider()
            Button("Chapters") { runInInspector(model.extractSmartChapters) }
                .accessibilityIdentifier("ai.chapters")
                .axLeaf("HeaderBar.MenuItem.Chapters")
                .disabled(!model.isAIAvailable(for: .summary))
            Button("Action Items") { runInInspector(model.extractActionItems) }
                .accessibilityIdentifier("ai.action_items")
                .axLeaf("HeaderBar.MenuItem.ActionItems")
                .disabled(!model.isAIAvailable(for: .prompts))
        } label: {
            Image(systemName: "sparkles")
        }
        .menuStyle(.button)
        .buttonStyle(GlyphButtonStyle(tinted: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Summary, chat, chapters and action items")
        .accessibilityLabel("AI")
        .accessibilityIdentifier("toolbar.ai")
        .axLeaf("HeaderBar.Menu.AI")
    }

    /// Chapters and action items land in the Info inspector, so a run started here has to open it there.
    private func runInInspector(_ run: () -> Void) {
        InspectorVisibility.showInfo(in: DefaultsStore.current, isNarrow: model.transcriptPaneIsNarrow)
        run()
    }

    private var groupDivider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, DS.Spacing.hair)
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
            Text("Jump to time").font(DS.Font.caption).foregroundStyle(DS.Color.secondaryText)
            HStack(spacing: 6) {
                TextField("mm:ss", text: $jumpDraft)
                    .textFieldStyle(.plain)
                    .focused($jumpFocused)
                    .fieldChrome(focused: jumpFocused)
                    .frame(width: 100)
                    .onSubmit { commitJump() }
                    .axLeaf("HeaderBar.TextField.JumpTime")
                Button("Go", action: commitJump)
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                    .disabled(Timecode.parse(jumpDraft) == nil)
                    .axLeaf("HeaderBar.Button.JumpGo")
            }
        }
        .padding(DS.Spacing.regular)
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
