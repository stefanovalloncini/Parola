import SwiftUI

/// The floating Liquid Glass controls, bottom centre.
struct StageControls: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @State private var discarding: Int?

    nonisolated static let buttonHeight: CGFloat = 44
    nonisolated static let bottomInset: CGFloat = 24
    /// The bar, its inset from the window edge and 24 pt of air above it, which the text column never enters.
    nonisolated static let reservedHeight: CGFloat = buttonHeight + bottomInset + DS.Spacing.large
    nonisolated static let stopWidth: CGFloat = 96

    /// Which controls a Stage state gets: the bar until Stop, one pill while the take winds down, none once it is over.
    enum Layout: Equatable {
        case bar
        case finishing
        case stopTranscribing
        case none
    }

    nonisolated static func layout(for mode: StageMode) -> Layout {
        switch mode {
        case .countIn, .preparing, .starting, .live, .paused: .bar
        case .finishing: .finishing
        case .transcribing: .stopTranscribing
        case .landing, .failed: .none
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: DS.Spacing.small) {
            switch Self.layout(for: take.mode) {
            case .bar: bar
            case .finishing: finishingPill
            case .stopTranscribing: stopTranscribingButton
            case .none: EmptyView()
            }
        }
        .alert("Discard this recording?", isPresented: confirmingDiscard, presenting: discarding) { takeID in
            // Return keeps the take: only a deliberate click deletes it.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
                .axLeaf("Stage.Button.KeepRecording")
            Button("Discard", role: .destructive) {
                Task { await Self.discard(takeID, model: model) }
            }
            .axLeaf("Stage.Button.ConfirmDiscard")
        } message: { _ in
            Text("The audio is deleted.")
        }
    }

    private var finishingPill: some View {
        Button {} label: {
            HStack(spacing: DS.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Finishing…")
            }
            .font(DS.Font.bodyStrong)
        }
        .buttonStyle(GlassCapsuleButtonStyle(height: Self.buttonHeight, horizontalPadding: DS.Spacing.medium, minWidth: Self.stopWidth))
        .disabled(true)
        .accessibilityLabel("Finishing the recording")
        .axLeaf("Stage.Button.Finishing")
    }

    /// The take's audio is in the library either way; this only stops the words.
    private var stopTranscribingButton: some View {
        Button {
            model.stopTranscribingTake()
        } label: {
            Label("Stop Transcribing", systemImage: "stop.fill")
                .labelStyle(.titleAndIcon)
                .font(DS.Font.bodyStrong)
        }
        .buttonStyle(GlassCapsuleButtonStyle(height: Self.buttonHeight, horizontalPadding: DS.Spacing.medium, minWidth: Self.stopWidth))
        .help("The recording stays in your library.")
        .accessibilityLabel("Stop Transcribing")
        .axLeaf("Stage.Button.StopTranscribing")
    }

    private var bar: some View {
        HStack(spacing: DS.Spacing.regular) {
            pauseButton
            Button {
                model.addTakeMarker()
            } label: {
                Label("Mark", systemImage: "flag.fill")
            }
            .buttonStyle(GlassCapsuleButtonStyle(height: Self.buttonHeight, horizontalPadding: 18))
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!take.isCapturing)
            .help("Add Marker")
            .accessibilityLabel("Add Marker")
            .axLeaf("Stage.Button.Mark")
            if take.isArming {
                cancelButton
            } else {
                stopButton
            }
            Button {
                discarding = take.takeID
            } label: {
                Label("Discard…", systemImage: "xmark")
            }
            .buttonStyle(GlassCapsuleButtonStyle(prominence: .secondary, height: Self.buttonHeight, horizontalPadding: 18))
            .disabled(!take.isCapturing)
            .help("Discard Recording…")
            .accessibilityLabel("Discard Recording…")
            .axLeaf("Stage.Button.Discard")
        }
        .labelStyle(.titleAndIcon)
        .font(DS.Font.bodyStrong)
    }

    private var stopButton: some View {
        Button {
            model.stopRecordingAndTranscribe()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(GlassCapsuleButtonStyle(
            prominence: .tinted(DS.Color.recordingFill),
            height: Self.buttonHeight,
            horizontalPadding: DS.Spacing.medium,
            minWidth: Self.stopWidth
        ))
        .keyboardShortcut(.return, modifiers: .command)
        .help("Stop recording and transcribe.")
        .accessibilityLabel("Stop Recording")
        .axLeaf("Stage.Button.Stop")
    }

    /// Nothing is recorded yet, so the take ends on the spot, with no confirmation and no entry.
    private var cancelButton: some View {
        Button {
            model.cancelArmingTake()
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(GlassCapsuleButtonStyle(height: Self.buttonHeight, horizontalPadding: DS.Spacing.medium, minWidth: Self.stopWidth))
        .keyboardShortcut(Self.cancelShortcut(titleFocused: model.takeTitleHasFocus))
        .help("Cancel the recording before it starts.")
        .accessibilityLabel("Cancel Recording")
        .axLeaf("Stage.Button.Cancel")
    }

    /// Esc cancels a take that is still starting, unless the title field has the keyboard: there it only leaves the field.
    nonisolated static func cancelShortcut(titleFocused: Bool) -> KeyboardShortcut? {
        titleFocused ? nil : .cancelAction
    }

    private var pauseButton: some View {
        let title: LocalizedStringKey = take.isPaused ? "Resume" : "Pause"
        let spoken: LocalizedStringKey = take.isPaused ? "Resume Recording" : "Pause Recording"
        return Button {
            Self.togglePause(model)
        } label: {
            Label(title, systemImage: take.isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(GlassCapsuleButtonStyle(height: Self.buttonHeight, horizontalPadding: 18))
        .disabled(!take.isCapturing)
        .help(spoken)
        .accessibilityLabel(spoken)
        .axLeaf("Stage.Button.Pause")
    }

    private var confirmingDiscard: Binding<Bool> {
        Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })
    }

    /// Pause and Space: a recording take pauses, a paused one picks up again.
    static func togglePause(_ model: AppModel) {
        if model.recording?.isPaused == true {
            model.resumeTake()
        } else {
            model.pauseTake()
        }
    }

    /// The confirmation names one take; by the time it is answered a newer take may hold the Stage, and that one stays.
    @discardableResult
    static func discard(_ takeID: Int, model: AppModel) async -> Bool {
        guard model.recording?.takeID == takeID else { return false }
        await model.discardTake()
        return true
    }
}

/// A Liquid Glass capsule of an exact height, clear or filled; the filled one carries white labels.
struct GlassCapsuleButtonStyle: ButtonStyle {
    enum Prominence {
        case standard
        case secondary
        case tinted(Color)
    }

    var prominence: Prominence = .standard
    var height: CGFloat
    var horizontalPadding: CGFloat = DS.Spacing.medium
    var minWidth: CGFloat?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minWidth, minHeight: height, maxHeight: height)
            .foregroundStyle(foreground)
            .background { fill }
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch prominence {
        case .standard: DS.Color.primaryText
        case .secondary: DS.Color.secondaryText
        case .tinted: .white
        }
    }

    /// Solid rather than a glass tint, which greys out while the window is inactive.
    @ViewBuilder
    private var fill: some View {
        if case .tinted(let tint) = prominence {
            Capsule().fill(tint)
        }
    }
}
