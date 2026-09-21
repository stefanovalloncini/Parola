import SwiftUI
import ParolaCore

/// The model, language and options apply to the next run, so only the pages that can start one show them.
enum IntakeSettings {
    static func areShown(
        route: AppModel.Route,
        isBrowsingLibrary: Bool,
        settingsPreview: Bool = false,
        introductionPresented: Bool = false
    ) -> Bool {
        guard !settingsPreview, !introductionPresented else { return false }
        guard route == .transcript else { return false }
        return !isBrowsingLibrary
    }
}

struct ContentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @State private var optionsOpen = false
    @State private var measuredIntakeWidth: CGFloat = 0

    var body: some ToolbarContent {
        if showsIntakeSettings {
            ToolbarItem(placement: .navigation) {
                intakeCapsule
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredIntakeWidth = $0 }
            }
        }
        ToolbarSpacer(.flexible, placement: .navigation)
        ToolbarItemGroup(placement: .primaryAction) {
            if showsSearch {
                ToolbarSearchField(intakeWidth: intakeWidth)
            }
            if isRecording {
                Button {
                    model.stopRecordingAndTranscribe()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(DS.Color.danger)
                .help("Stop recording and transcribe.")
                .accessibilityIdentifier("toolbar.stopRecording")
                .axLeaf("Toolbar.Button.StopRecording")
            } else {
                newMenu
            }
        }
    }

    private var intakeCapsule: some View {
        HStack(spacing: 0) {
            ModelPickerView()
            segmentDivider
            LanguagePickerView()
                .disabled(selectedModelIsEnglishOnly)
                .modifier(LanguageNoticeHelpModifier(notice: languageControlNotice))
            segmentDivider
            optionsSegment
        }
        .toolbarCapsule()
    }

    private var segmentDivider: some View {
        DS.Color.separator
            .frame(width: 0.5, height: ToolbarCapsule.height)
    }

    private var optionsSegment: some View {
        IntakeSegment {
            optionsOpen.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.accent)
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
                    .font(DS.Font.secondary)
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
            Button("Open Files…") { model.presentOpenPanel() }
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

    /// The capsule's own width once it has reported one, so the search field's budget is the toolbar's, not a guess.
    private var intakeWidth: CGFloat {
        guard showsIntakeSettings else { return 0 }
        return measuredIntakeWidth > 0 ? measuredIntakeWidth : ToolbarSearchMetrics.defaultIntakeWidth
    }

    private var showsSearch: Bool {
        ToolbarSearchMetrics.isShown(introductionPresented: model.introduction.isPresented)
    }

    private var showsIntakeSettings: Bool {
        IntakeSettings.areShown(
            route: model.route,
            isBrowsingLibrary: model.isBrowsingLibrary,
            settingsPreview: model.mode == .test && model.settingsRoutePreview,
            introductionPresented: model.introduction.isPresented
        )
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
