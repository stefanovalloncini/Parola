import SwiftUI
import ParolaCore

/// An empty library's one record control, then the ways in that need no recording.
struct EmptyLibraryHero: View {
    @Environment(AppModel.self) private var model

    /// The remembered source while both can record, else the one the build allows; nil when neither can.
    static func source(remembered: AppModel.RecordSource, features: FeatureSet) -> AppModel.RecordSource? {
        offersSourceChoice(features: features) ? remembered : RecordControl.primarySource(features: features)
    }

    static func offersSourceChoice(features: FeatureSet) -> Bool {
        features.isEnabled(.micRecording) && features.isEnabled(.meetings)
    }

    /// File ▸ New Recording and New System Audio Recording.
    static func shortcutHint(for source: AppModel.RecordSource) -> String {
        source == .microphone ? "⌘N" : "⌥⌘N"
    }

    static func dropPrompt(offersRecording: Bool, bundle: Bundle = .main) -> String {
        offersRecording
            ? String(localized: "or drop audio and video anywhere", bundle: bundle)
            : String(localized: "Drop audio and video anywhere", bundle: bundle)
    }

    var body: some View {
        let source = Self.source(remembered: model.lastRecordSource, features: model.features)
        VStack(spacing: 0) {
            if let source {
                recordButton(source)
                recordCaption(source)
                    .padding(.top, DS.Spacing.regular)
                if Self.offersSourceChoice(features: model.features) {
                    sourcePicker
                        .padding(.top, DS.Spacing.medium)
                }
            }
            IntakeSettingsButton(style: .quiet, leaf: "Settings")
                .padding(.top, source == nil ? 0 : DS.Spacing.small)
            waysIn(offersRecording: source != nil)
                .padding(.top, DS.Spacing.large)
        }
        .axBranch("Hero")
    }

    private func recordButton(_ source: AppModel.RecordSource) -> some View {
        Button {
            model.startRecording(source: source)
        } label: {
            // An explicit fill, so the dot stays red in an inactive window; the plain style fades it while disabled.
            Circle()
                .fill(DS.Color.recordingFill)
                .frame(width: 28, height: 28)
                .frame(width: 96, height: 96)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!model.canStartTake(source))
        .help(source == .microphone ? Text("Record from the microphone") : Text("Record system audio"))
        .accessibilityLabel("Record")
        .axLeaf("Record")
    }

    /// The button already says Record to VoiceOver; this line is for the eye.
    private func recordCaption(_ source: AppModel.RecordSource) -> some View {
        HStack(spacing: DS.Spacing.snug) {
            Text("Record")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            Text(verbatim: Self.shortcutHint(for: source))
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .accessibilityHidden(true)
    }

    private var sourcePicker: some View {
        @Bindable var model = model
        return Picker("Recording source", selection: $model.lastRecordSource) {
            Text("Microphone").tag(AppModel.RecordSource.microphone)
            Text("System Audio").tag(AppModel.RecordSource.systemAudio)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .axLeaf("Source")
    }

    private func waysIn(offersRecording: Bool) -> some View {
        HStack(spacing: DS.Spacing.snug) {
            Text(verbatim: Self.dropPrompt(offersRecording: offersRecording))
                .foregroundStyle(DS.Color.secondaryText)
            separator
            Button("Open Files…") { model.presentOpenPanel() }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.accentInk)
                .axLeaf("OpenFiles")
            if model.features.isEnabled(.youtube) {
                separator
                Button("Paste a link") { model.openLinkSheet(prefill: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.accentInk)
                    .axLeaf("PasteLink")
            }
        }
        .font(DS.Font.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(DS.Color.secondaryText)
            .accessibilityHidden(true)
    }
}
