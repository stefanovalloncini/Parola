import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @State private var optionsOpen = false

    var body: some ToolbarContent {
        if showsIntakeSettings {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: DS.Spacing.small) {
                    ModelPickerView()
                    LanguagePickerView()
                        .disabled(selectedModelIsEnglishOnly)
                        .modifier(LanguageNoticeHelpModifier(notice: languageControlNotice))
                }
                // Without this the pills' own capsules run flush into the toolbar's rounded ends.
                .padding(.horizontal, 5)
            }
            ToolbarItem(placement: .navigation) {
                optionsButton
            }
        }
        ToolbarSpacer(.flexible, placement: .navigation)
        ToolbarItemGroup(placement: .primaryAction) {
            if isRecording {
                Button {
                    model.stopRecordingAndTranscribe()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .help("Stop recording and transcribe.")
                .accessibilityIdentifier("toolbar.stopRecording")
                .axLeaf("Toolbar.Button.StopRecording")
            } else {
                newMenu
            }
        }
    }

    private var optionsButton: some View {
        Button {
            optionsOpen.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .overlay(alignment: .topTrailing) {
                    if optionsActive {
                        Circle()
                            .fill(DS.Color.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .help("Transcription options")
        .accessibilityIdentifier("toolbar.options")
        .axLeaf("Toolbar.Menu.Options")
        .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
            optionsPopover
        }
    }

    private var optionsPopover: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            if let notice = model.englishOnlyAutoNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warningText)
                    .axLeaf("Toolbar.Label.EnglishOnlyAutoNotice")
            }
            if selectedModelSupportsTranslate {
                Toggle(isOn: $model.translate) {
                    Text("Translate")
                }
                .help("Translate to English instead of transcribing in the source language.")
                .accessibilityIdentifier("toolbar.translate")
                .axLeaf("Toolbar.Toggle.Translate")
            }
            Toggle(isOn: $model.diarize) {
                Text("Diarize")
            }
            .help("Identify multiple speakers in the audio (slower).")
            .accessibilityIdentifier("toolbar.diarize")
            .axLeaf("Toolbar.Toggle.Diarize")
            if model.diarize {
                Picker("Speakers", selection: $model.expectedSpeakersRaw) {
                    Text("Auto").tag(0)
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .help("How many speakers to expect. Auto lets the diarizer decide.")
                .accessibilityIdentifier("toolbar.expectedSpeakers")
                .axLeaf("Toolbar.Menu.ExpectedSpeakers")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(DS.Spacing.medium)
        .frame(width: 240)
    }

    private var optionsActive: Bool {
        model.translate || model.diarize
    }

    private var newMenu: some View {
        Menu {
            Button("Open File…") { model.presentOpenPanel() }
                .accessibilityIdentifier("toolbar.openFile")
                .axLeaf("Toolbar.MenuItem.NewOpenFile")
            if model.features.isEnabled(.micRecording) || model.features.isEnabled(.meetings) {
                Divider()
                if model.features.isEnabled(.micRecording) {
                    Button("Record Microphone") { model.startRecording(source: .microphone) }
                        .accessibilityIdentifier("toolbar.record.microphone")
                        .axLeaf("Toolbar.MenuItem.NewRecordMicrophone")
                }
                if model.features.isEnabled(.meetings) {
                    Button("Record System Audio") { model.startRecording(source: .systemAudio) }
                        .accessibilityIdentifier("toolbar.record.system")
                        .axLeaf("Toolbar.MenuItem.NewRecordSystem")
                }
            }
            if model.features.isEnabled(.youtube) {
                Divider()
                Button("YouTube URL…") { model.youtubeSheetOpen = true }
                    .accessibilityIdentifier("toolbar.youtube")
                    .axLeaf("Toolbar.MenuItem.NewYouTube")
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .disabled(isBusy)
        .help("Start a new transcription.")
        .accessibilityIdentifier("toolbar.new")
        .axLeaf("Toolbar.Menu.New")
    }

    /// The model, language and options apply to the next run, so the library's own lists hide them.
    private var showsIntakeSettings: Bool {
        !model.isBrowsingLibrary
    }

    private var selectedModelIsEnglishOnly: Bool {
        model.selectedModelCapabilities.supportedLanguages.isEnglishOnly
    }
    private var selectedModelSupportsTranslate: Bool {
        model.selectedModelCapabilities.supportsTranslate
    }

    /// Why the disabled language pill reads what it reads: the auto-English notice takes priority
    /// since it explains what the run will actually do, then the explicit-language mismatch warning.
    private var languageControlNotice: String? {
        model.englishOnlyAutoNotice ?? model.languageMismatchWarning
    }

    private var isBusy: Bool {
        switch model.phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }
}

private struct LanguageNoticeHelpModifier: ViewModifier {
    let notice: String?
    func body(content: Content) -> some View {
        content.help(notice ?? "")
    }
}
