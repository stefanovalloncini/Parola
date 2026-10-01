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

    var body: some View {
        GlassEffectContainer(spacing: DS.Spacing.small) {
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
                .disabled(take.state == .finishing)
                .help("Stop recording and transcribe.")
                .accessibilityLabel("Stop Recording")
                .axLeaf("Stage.Button.Stop")
                Button {
                    discarding = take.takeID
                } label: {
                    Label("Discard…", systemImage: "xmark")
                }
                .buttonStyle(GlassCapsuleButtonStyle(prominence: .secondary, height: Self.buttonHeight, horizontalPadding: 18))
                .disabled(take.state == .finishing)
                .help("Discard Recording…")
                .accessibilityLabel("Discard Recording…")
                .axLeaf("Stage.Button.Discard")
            }
            .labelStyle(.titleAndIcon)
            .font(DS.Font.bodyStrong)
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

/// A Liquid Glass capsule of an exact height, clear or tinted; the tinted one carries white labels.
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
            .contentShape(Capsule())
            .glassEffect(glass, in: Capsule())
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

    private var glass: Glass {
        switch prominence {
        case .standard, .secondary: .regular.interactive()
        case .tinted(let tint): .regular.tint(tint).interactive()
        }
    }
}
