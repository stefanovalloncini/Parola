import SwiftUI
import ParolaCore

struct ReadAloudVoiceSheet: View {
    let prompt: ReadAloudController.VoicePrompt

    @Environment(AppModel.self) private var model
    @State private var selection: VoiceID = .appleAutomatic

    private var languageName: String {
        LanguageDisplay.midSentenceName(for: prompt.language) ?? prompt.language
    }

    private var entries: [VoiceMenuEntry] {
        ReadAloudVoices.menuEntries(for: prompt.language, in: model.readAloud.appleInventory)
    }

    var body: some View {
        SheetFrame(
            titleVerbatim: String(localized: "Choose a voice to read \(languageName)"),
            onClose: { model.dismissVoicePrompt() },
            content: { contentBody },
            footer: { footerBody }
        )
        .sheetSize(width: 480, minHeight: 200, maxHeight: 420)
        .footerHasCancel()
        .axBranch("VoiceSheet")
        .onAppear { selection = initialSelection }
        .onDisappear { Task { await model.readAloud.stopPreview() } }
    }

    private var initialSelection: VoiceID {
        guard let saved = model.readAloudVoices[ReadAloudVoices.key(for: prompt.language)],
              entries.contains(where: { $0.voice == saved && $0.isUsable }) else { return .appleAutomatic }
        return saved
    }

    @ViewBuilder
    private var contentBody: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            switch prompt.mode {
            case .choose:
                ReadAloudVoiceCard(
                    entries: entries,
                    selection: $selection,
                    isPreviewing: model.readAloud.previewing != nil,
                    canPreview: model.readingBlockedReason == nil,
                    preview: { Task { await model.previewVoice(selection, language: prompt.language) } },
                    stopPreview: { Task { await model.readAloud.stopPreview() } },
                    use: { Task { await model.chooseVoice(selection, for: prompt.language) } }
                )
            case .noVoice:
                Text("No voice on this Mac reads \(languageName).")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf("Text.NoVoice")
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.regular)
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Get more voices…") { model.openMoreVoices() }
                .sheetSecondaryAction()
                .axLeaf("Button.MoreVoices")
            Spacer(minLength: 0)
            if prompt.mode == .choose {
                Button("Use the built-in voice for now") { Task { await model.readWithBuiltInVoiceForNow() } }
                    .sheetSecondaryAction()
                    .axLeaf("Button.BuiltInForNow")
            }
            Button("Cancel") { model.dismissVoicePrompt() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("Button.Cancel")
        }
    }
}

struct ReadAloudVoiceCard: View {
    let entries: [VoiceMenuEntry]
    @Binding var selection: VoiceID
    let isPreviewing: Bool
    let canPreview: Bool
    let preview: () -> Void
    let stopPreview: () -> Void
    let use: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Built-in")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            Text("Built into macOS. Ready now.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
            Picker("Voice", selection: $selection) {
                ForEach(entries) { entry in
                    Text(entry.title).tag(entry.voice).disabled(!entry.isUsable)
                }
            }
            .pickerStyle(.menu)
            .axLeaf("Picker.Voice")
            HStack(spacing: DS.Spacing.small) {
                Spacer(minLength: 0)
                if isPreviewing {
                    Button("Stop", action: stopPreview)
                        .sheetSecondaryAction()
                        .axLeaf("Button.StopPreview")
                } else {
                    Button("Preview", action: preview)
                        .sheetSecondaryAction()
                        .disabled(!canPreview)
                        .axLeaf("Button.Preview")
                }
                Button("Use", action: use)
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("Button.Use")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.medium)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Color.separator, lineWidth: 0.5)
        )
    }
}
