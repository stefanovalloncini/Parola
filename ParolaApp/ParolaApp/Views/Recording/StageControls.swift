import SwiftUI

/// The floating Liquid Glass controls, bottom centre.
struct StageControls: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var discarding: Int?
    @State private var holdsPill = false

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

    enum Control {
        case pause, mark, stop, cancel, discard, finishing, stopTranscribing
    }

    /// The bar's controls with a key of their own; their help names it, as a menu shows it beside the command.
    enum KeyedControl {
        case pause, resume, mark, stop, cancel
    }

    nonisolated static func help(for control: KeyedControl, bundle: Bundle = .main) -> String {
        let space = String(localized: "Space", bundle: bundle)
        switch control {
        case .pause: return withKey(String(localized: "Pause Recording", bundle: bundle), space)
        case .resume: return withKey(String(localized: "Resume Recording", bundle: bundle), space)
        case .mark: return withKey(String(localized: "Add Marker", bundle: bundle), "⌘B")
        case .stop: return withKey(String(localized: "Stop recording and transcribe", bundle: bundle), "⌘↩")
        case .cancel: return withKey(String(localized: "Cancel the recording before it starts", bundle: bundle), "Esc")
        }
    }

    private nonisolated static func withKey(_ text: String, _ key: String) -> String {
        text + " (" + key + ")"
    }

    /// The glass each control morphs from: whatever ends the take sits in Stop's capsule, so Stop becomes the Finishing pill and then Stop Transcribing.
    enum GlassShape: Hashable, Sendable {
        case pause, mark, end, discard
    }

    /// Under Reduce Motion no glass carries an identity, so nothing morphs and the controls only crossfade.
    nonisolated static func glassShape(_ control: Control, reduceMotion: Bool) -> GlassShape? {
        guard !reduceMotion else { return nil }
        switch control {
        case .pause: return .pause
        case .mark: return .mark
        case .discard: return .discard
        case .stop, .cancel, .finishing, .stopTranscribing: return .end
        }
    }

    static func layoutChange(reduceMotion: Bool) -> Animation {
        reduceMotion ? DS.Motion.crossfade : DS.Motion.controlsMorph
    }

    /// A file take can pass through finishing in a moment; its pill stays this long, so the bar's fold plays out before Stop Transcribing takes its place.
    nonisolated static let pillHold: Duration = .milliseconds(600)

    nonisolated static func shownLayout(_ layout: Layout, holdingPill: Bool) -> Layout {
        layout == .stopTranscribing && holdingPill ? .finishing : layout
    }

    var body: some View {
        let layout = Self.layout(for: take.mode)
        let shown = Self.shownLayout(layout, holdingPill: holdsPill)
        GlassEffectContainer(spacing: DS.Spacing.small) {
            switch shown {
            case .bar: bar
            case .finishing, .stopTranscribing: windingDown(shown)
            case .none: EmptyView()
            }
        }
        .animation(Self.layoutChange(reduceMotion: reduceMotion), value: shown)
        .onChange(of: layout) { old, new in
            if old == .bar, new == .finishing || new == .stopTranscribing { holdsPill = true }
        }
        .task(id: holdsPill) {
            guard holdsPill else { return }
            try? await Task.sleep(for: Self.pillHold, clock: model.clock)
            holdsPill = false
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

    /// One place for both, so the pill turning into Stop Transcribing never cuts the bar's fold short.
    @ViewBuilder
    private func windingDown(_ shown: Layout) -> some View {
        if shown == .finishing {
            finishingPill
        } else {
            stopTranscribingButton
        }
    }

    /// A word in the controls' place, not a control: there is nothing to press while the take winds down.
    private var finishingPill: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text("Finishing…")
        }
        .font(DS.Font.bodyStrong)
        .foregroundStyle(DS.Color.secondaryText)
        .padding(.horizontal, DS.Spacing.medium)
        .frame(minWidth: Self.stopWidth, minHeight: Self.buttonHeight, maxHeight: Self.buttonHeight)
        .glassEffect(.regular, in: Capsule())
        .morphs(as: .finishing, in: glass, reduceMotion: reduceMotion)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finishing the recording")
        .axLeaf("Stage.Label.Finishing")
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
        .morphs(as: .stopTranscribing, in: glass, reduceMotion: reduceMotion)
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
            .disabled(!take.isCapturing)
            .help(Self.help(for: .mark))
            .accessibilityLabel("Add Marker")
            .axLeaf("Stage.Button.Mark")
            .morphs(as: .mark, in: glass, reduceMotion: reduceMotion)
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
            .morphs(as: .discard, in: glass, reduceMotion: reduceMotion)
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
        .help(Self.help(for: .stop))
        .accessibilityLabel("Stop Recording")
        .axLeaf("Stage.Button.Stop")
        .morphs(as: .stop, in: glass, reduceMotion: reduceMotion)
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
        .help(Self.help(for: .cancel))
        .accessibilityLabel("Cancel Recording")
        .axLeaf("Stage.Button.Cancel")
        .morphs(as: .cancel, in: glass, reduceMotion: reduceMotion)
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
        .help(Self.help(for: take.isPaused ? .resume : .pause))
        .accessibilityLabel(spoken)
        .axLeaf("Stage.Button.Pause")
        .morphs(as: .pause, in: glass, reduceMotion: reduceMotion)
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

private extension View {
    /// Ties the control's glass to its shape in the bar's container; under Reduce Motion the glass fades in and out instead.
    func morphs(as control: StageControls.Control, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
        glassEffectID(StageControls.glassShape(control, reduceMotion: reduceMotion), in: namespace)
            .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
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
