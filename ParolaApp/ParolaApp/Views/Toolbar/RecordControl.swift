import SwiftUI
import ParolaCore

/// "● Record ⌄" in the toolbar; a running take puts its session capsule in the same item.
struct RecordControl: View {
    @Environment(AppModel.self) private var model

    /// The microphone when the deployment allows it, else system audio; nil hides the control.
    static func primarySource(features: FeatureSet) -> AppModel.RecordSource? {
        if features.isEnabled(.micRecording) { return .microphone }
        if features.isEnabled(.meetings) { return .systemAudio }
        return nil
    }

    /// A menu holding only what the button already does would be a second way to the same take.
    static func offersModes(features: FeatureSet, detectedMeetingApp: String? = nil) -> Bool {
        let modes = [ParolaFeature.micRecording, .meetings, .liveCaptions, .dictation].filter(features.isEnabled).count
        return modes > 1 || (features.isEnabled(.meetings) && detectedMeetingApp != nil)
    }

    /// The meeting app the menu bar offers too; the model's own flag is set only while its alert blocks the window.
    static func detectedMeetingApp(for model: AppModel) -> String? {
        model.features.isEnabled(.meetings) ? model.detectedMeetingAppName : nil
    }

    var body: some View {
        if let take = model.recording, take.isRunning, model.recordingCountdown == nil {
            SessionCapsule(take: take)
        } else if let source = Self.primarySource(features: model.features) {
            recordButton(source)
        }
    }

    private var showsModes: Bool {
        Self.offersModes(features: model.features, detectedMeetingApp: Self.detectedMeetingApp(for: model))
    }

    private func recordButton(_ source: AppModel.RecordSource) -> some View {
        Self.styledButton(action: { model.startRecording(source: source) }, showsModes: showsModes)
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

    /// The plain glass the other toolbar buttons wear; only the dot inside stays red.
    static func styledButton(action: @escaping () -> Void, showsModes: Bool) -> some View {
        Button(action: action) {
            RecordButtonLabel(showsModes: showsModes)
        }
        .buttonStyle(.glass)
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
                    if let app = Self.detectedMeetingApp(for: model) {
                        Button { model.startMeetingRecording(appName: app) } label: {
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

/// The dot, "Record", and the chevron: the only red in the toolbar is the dot.
struct RecordButtonLabel: View {
    var showsModes: Bool

    @Environment(\.isEnabled) private var isEnabled

    static let dotColor = DS.Color.recordingFill

    /// `.glass` dims inherited-colour content on its own; the dot's explicit colour needs this by hand.
    static func contentOpacity(isEnabled: Bool) -> Double {
        isEnabled ? 1 : DS.Opacity.disabled
    }

    var body: some View {
        HStack(spacing: DS.Spacing.snug) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Self.dotColor)
                .opacity(Self.contentOpacity(isEnabled: isEnabled))
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
}
