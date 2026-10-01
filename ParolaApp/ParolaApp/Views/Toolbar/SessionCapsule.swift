import AppKit
import SwiftUI

/// The running take on every page: "● 12:34 | Stop". The time goes back to the Stage; a narrow window drops the meter, never Stop.
struct SessionCapsule: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @State private var isOnScreen = true
    @State private var showsMeter: Bool?

    nonisolated static let height: CGFloat = 36
    nonisolated static let meterMinimumWindowWidth: CGFloat = 1000

    /// What VoiceOver reads for the time: what the take is doing, then its length in words.
    nonisolated static func label(
        for take: RecordingSession, now: Date, bundle: Bundle = .main, locale: Locale = AppFormat.locale
    ) -> String {
        TakeRemote.spokenStatus(for: take, at: now, bundle: bundle, locale: locale)
    }

    nonisolated static func showsMeter(windowWidth: CGFloat) -> Bool {
        windowWidth >= meterMinimumWindowWidth
    }

    /// Acts on what the capsule drew: Stop and Cancel both go the shared way, but a Cancel that finds the take recording by now leaves it.
    static func stopOrCancel(_ model: AppModel, cancels: Bool) {
        guard !cancels || model.recording?.isArming == true else { return }
        TakeRemote.stop(model)
    }

    var body: some View {
        SessionCapsuleFace(
            take: take,
            showsMeter: showsMeter ?? Self.showsMeter(windowWidth: model.mainWindow?.frame.width ?? 0),
            isOnScreen: isOnScreen,
            showStage: { model.showStage() },
            stop: { Self.stopOrCancel(model, cancels: $0) }
        )
        .background(WindowShownReader { isOnScreen = $0 })
        .background(WindowWidthReader { showsMeter = Self.showsMeter(windowWidth: $0) })
    }
}

/// The capsule as drawn. Its red is a solid fill under white text: a glass tint greys out while the window is inactive.
struct SessionCapsuleFace: View {
    let take: RecordingSession
    let showsMeter: Bool
    let isOnScreen: Bool
    let showStage: () -> Void
    /// Told whether the button read Cancel when it was clicked.
    let stop: (_ cancels: Bool) -> Void

    var body: some View {
        if isOnScreen, take.state == .recording, let origin = take.clockOrigin {
            TimelineView(.periodic(from: origin, by: 1)) { context in
                capsule(at: context.date)
            }
        } else {
            capsule(at: Date())
        }
    }

    private func capsule(at now: Date) -> some View {
        HStack(spacing: 0) {
            Button(action: showStage) {
                HStack(spacing: DS.Spacing.snug) {
                    dot
                    Text(verbatim: StageClock.text(seconds: Int(take.elapsed(at: now))))
                        .font(DS.Font.takeTimerCompact)
                    if take.isPaused {
                        Text("Paused")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, showsLevel ? DS.Spacing.small : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(SessionCapsuleButtonStyle())
            .help("Show Recording")
            .accessibilityLabel(Text(verbatim: SessionCapsule.label(for: take, now: now)))
            .accessibilityHint("Show Recording")
            .accessibilityAddTraits(.updatesFrequently)
            .axLeaf("Toolbar.Button.SessionTime")
            if showsLevel {
                SessionMeter()
                    .padding(.trailing, 10)
            }
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
            stopButton
        }
        .font(DS.Font.bodyStrong)
        .foregroundStyle(.white)
        .frame(height: SessionCapsule.height)
        .background(Capsule().fill(DS.Color.recordingFill))
        .fixedSize()
    }

    @ViewBuilder
    private var stopButton: some View {
        let starting = take.isArming
        Button { stop(starting) } label: {
            Text(starting ? "Cancel" : "Stop")
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SessionCapsuleButtonStyle())
        .disabled(take.state == .finishing)
        .help(starting ? "Cancel the recording before it starts." : "Stop recording and transcribe.")
        .accessibilityLabel(starting ? "Cancel" : "Stop Recording")
        .axLeaf("Toolbar.Button.SessionStop")
    }

    /// The meter shows a capture that can still move; a paused take says so in words instead.
    private var showsLevel: Bool {
        showsMeter && (take.state == .recording || take.isArming)
    }

    @ViewBuilder
    private var dot: some View {
        switch take.state {
        case .recording:
            RecDot(color: .white, pulsesFrom: isOnScreen ? take.clockOrigin : nil)
        case .paused:
            RecDot(color: DS.Palette.warning)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
        default:
            RecDot(color: .white.opacity(0.5))
        }
    }
}

/// White labels on the red that dim while pressed or disabled.
private struct SessionCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : DS.Opacity.disabled)
    }
}

/// The take's last two seconds of level, in the capsule's white, on the Stage band's curve.
private struct SessionMeter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let barCount = 20
    nonisolated static let barWidth: CGFloat = 2
    nonisolated static let gap: CGFloat = 1
    nonisolated static let height: CGFloat = 16

    var body: some View {
        if reduceMotion {
            TimelineView(.animation(minimumInterval: 0.25)) { _ in bars }
        } else {
            let _ = model.takeLevelTick
            bars
        }
    }

    private var bars: some View {
        let levels = model.takeLevels?.recent(Self.barCount) ?? Array(repeating: 0, count: Self.barCount)
        let newest = Double(levels.last ?? 0)
        let width = CGFloat(Self.barCount) * (Self.barWidth + Self.gap) - Self.gap
        return Canvas { context, size in
            var path = Path()
            for (index, level) in levels.enumerated() {
                let barHeight = LevelBars.height(for: level, idle: 2, max: size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (Self.barWidth + Self.gap),
                    y: (size.height - barHeight) / 2,
                    width: Self.barWidth,
                    height: barHeight
                )
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1), style: .continuous)
            }
            context.fill(path, with: .color(.white.opacity(0.85)))
        }
        .frame(width: width, height: Self.height)
        .accessibilityRepresentation {
            Text(verbatim: AppFormat.percent(newest))
                .accessibilityLabel("Input level")
                .accessibilityValue(Text(verbatim: AppFormat.percent(newest)))
                .accessibilityAddTraits(.updatesFrequently)
                .axLeaf("Toolbar.Meter.SessionLevel")
        }
    }
}

/// The width of the window this sits in, as it opens and each time it is resized.
private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: (any NSObjectProtocol)?
        private var reported: CGFloat?

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // A view joins its window inside SwiftUI's update, which must not change the capsule's state.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let width = window?.frame.width, width != reported else { return }
            reported = width
            onChange?(width)
        }
    }
}
