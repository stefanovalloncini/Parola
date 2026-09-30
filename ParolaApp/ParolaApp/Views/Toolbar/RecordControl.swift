import SwiftUI
import ParolaCore

/// "● Record ⌄" in the toolbar; a take arming or recording puts its own control in the same item.
struct RecordControl: View {
    @Environment(AppModel.self) private var model

    /// The microphone when the deployment allows it, else system audio; nil hides the control.
    static func primarySource(features: FeatureSet) -> AppModel.RecordSource? {
        if features.isEnabled(.micRecording) { return .microphone }
        if features.isEnabled(.meetings) { return .systemAudio }
        return nil
    }

    /// A menu holding only what the button already does would be a second way to the same take.
    static func offersModes(features: FeatureSet) -> Bool {
        [ParolaFeature.micRecording, .meetings, .liveCaptions, .dictation].filter(features.isEnabled).count > 1
    }

    var body: some View {
        if case .recording = model.phase {
            RecordingToolbarButton()
        } else if let source = Self.primarySource(features: model.features) {
            recordButton(source)
        }
    }

    private var showsModes: Bool {
        Self.offersModes(features: model.features) || model.meetingDetectedApp != nil
    }

    private func recordButton(_ source: AppModel.RecordSource) -> some View {
        Button {
            model.startRecording(source: source)
        } label: {
            HStack(spacing: DS.Spacing.snug) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
                Text("Record")
                if showsModes {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.leading, DS.Spacing.hair)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.glassProminent)
        .tint(DS.Color.recordingFill)
        .disabled(!model.canStartTake(source))
        .help(source == .microphone ? "Record from the microphone" : "Record system audio")
        .accessibilityLabel("Record")
        .axLeaf("Toolbar.Button.Record")
        .overlay(alignment: .trailing) {
            if showsModes {
                modesMenu
            }
        }
    }

    /// Invisible and laid over the chevron: a Menu ignores the glass styles, and a Button can't open a menu.
    private var modesMenu: some View {
        Menu {
            Group {
                if model.features.isEnabled(.micRecording) {
                    Button { model.startRecording(source: .microphone) } label: {
                        Label("Microphone", systemImage: "mic")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.canStartTake(.microphone))
                    .axLeaf("Toolbar.MenuItem.RecordMicrophone")
                }
                if model.features.isEnabled(.meetings) {
                    Button { model.startRecording(source: .systemAudio) } label: {
                        Label("System Audio", systemImage: "speaker.wave.2")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.canStartTake(.systemAudio))
                    .axLeaf("Toolbar.MenuItem.RecordSystemAudio")
                    if let app = model.meetingDetectedApp {
                        Button { model.startMeetingRecording() } label: {
                            Label("Record \(app) Meeting", systemImage: DS.categorySymbol(for: .meeting))
                        }
                        .disabled(!model.canStartTake(.systemAudio))
                        .axLeaf("Toolbar.MenuItem.RecordMeeting")
                    }
                }
                if model.features.isEnabled(.liveCaptions) || model.features.isEnabled(.dictation) {
                    Divider()
                }
                if model.features.isEnabled(.liveCaptions) {
                    liveCaptionsItem
                }
                if model.features.isEnabled(.dictation) {
                    Button { model.startDictationFromIntent() } label: {
                        Label("Dictation", systemImage: DS.categorySymbol(for: .dictation))
                    }
                    .axLeaf("Toolbar.MenuItem.Dictation")
                }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Color.clear
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording options")
        .accessibilityLabel("Recording options")
        .axLeaf("Toolbar.Menu.RecordModes")
    }

    /// Captions already running can always be stopped; starting them needs a model that streams.
    private var liveCaptionsItem: some View {
        let active = model.liveCaptions?.isActive == true
        let reason = model.liveCaptionsUnavailableReason
        return Button { model.toggleLiveCaptions() } label: {
            Label(active ? "Stop Live Captions" : "Live Captions", systemImage: "captions.bubble")
        }
        .disabled(!active && reason != nil)
        .help(active ? "" : reason ?? "")
        .axLeaf("Toolbar.MenuItem.LiveCaptions")
    }
}
