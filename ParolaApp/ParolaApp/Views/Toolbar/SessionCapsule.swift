import AppKit
import SwiftUI

/// The running take on every page but the Stage: "● 12:34 | Stop". The time goes back to the Stage; a narrow window drops the meter, never Stop.
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

    /// The Stage has its own clock and Stop, so the toolbar leaves the take to it.
    static func shows(on model: AppModel) -> Bool {
        ContentRoutes.routeID(for: model) != .stage
    }

    var body: some View {
        SessionCapsuleFace(
            take: take,
            showsMeter: showsMeter ?? Self.showsMeter(windowWidth: model.mainWindow?.frame.width ?? 0),
            isOnScreen: isOnScreen,
            showStage: { model.showStage() },
            stop: { TakeRemote.stopOrCancel(model, cancels: $0) }
        )
        .background(WindowShownReader { isOnScreen = $0 })
        .background(WindowWidthReader { showsMeter = Self.showsMeter(windowWidth: $0) })
    }
}

/// The capsule as drawn: the Record button's plain glass, with only the dot in red.
struct SessionCapsuleFace: View {
    let take: RecordingSession
    let showsMeter: Bool
    let isOnScreen: Bool
    let showStage: () -> Void
    /// Told whether the button read Cancel when it was clicked.
    let stop: (_ cancels: Bool) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

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
                    Text(verbatim: TakeRemote.clock(for: take, now: now))
                        .font(DS.Font.takeTimerCompact)
                    if take.isPaused {
                        Text("Paused")
                            .foregroundStyle(.secondary)
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
                SessionMeter(isOnScreen: isOnScreen)
                    .padding(.trailing, 10)
            }
            Capsule()
                .fill(.primary.opacity(contrast == .increased ? 0.5 : 0.25))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
            stopButton
        }
        .foregroundStyle(.primary)
        .frame(height: SessionCapsule.height)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            if contrast == .increased {
                Capsule()
                    .strokeBorder(.primary.opacity(0.5), lineWidth: 1)
                    .accessibilityHidden(true)
            }
        }
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
        .accessibilityLabel(Text(verbatim: TakeRemote.endTitle(for: take)))
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
            RecDot(color: RecordButtonLabel.dotColor, pulsesFrom: isOnScreen ? take.clockOrigin : nil)
        case .paused:
            RecDot(color: DS.Palette.warning)
        default:
            RecDot(color: .secondary)
        }
    }
}

/// The glass holds still; the labels dim while pressed or disabled.
private struct SessionCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : DS.Opacity.disabled)
    }
}

/// The take's last two seconds of level, on the Stage band's curve.
struct SessionMeter: View {
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static let barCount = 20
    nonisolated static let barWidth: CGFloat = 2
    nonisolated static let gap: CGFloat = 1
    nonisolated static let height: CGFloat = 16
    nonisolated static let width = CGFloat(barCount) * (barWidth + gap) - gap

    var body: some View {
        // Only VoiceOver needs each sample in SwiftUI, to say the level; the bars' layer follows the take by itself.
        let _ = isOnScreen && model.voiceOverIsRunning ? model.takeLevelTick : 0
        let levels = Self.levels(of: model)
        let newest = Double(levels.last ?? 0)
        MeterLayer(
            levels: levels,
            ink: .primary.opacity(contrast == .increased ? 0.85 : 0.5),
            feed: isOnScreen ? MeterFeed(model: model, interval: reduceMotion ? 0.25 : nil) : nil
        )
        .frame(width: Self.width, height: Self.height)
        .accessibilityRepresentation {
            Text(verbatim: AppFormat.percent(newest))
                .accessibilityLabel("Input level")
                .accessibilityValue(Text(verbatim: AppFormat.percent(newest)))
                .accessibilityAddTraits(.updatesFrequently)
                .axLeaf("Toolbar.Meter.SessionLevel")
        }
    }

    static func levels(of model: AppModel) -> [Float] {
        model.takeLevels?.recent(barCount) ?? Array(repeating: 0, count: barCount)
    }

    /// One bar per level, newest on the right, each standing on the box's middle.
    nonisolated static func barsPath(_ levels: [Float], height: CGFloat) -> Path {
        var path = Path()
        for (index, level) in levels.enumerated() {
            let barHeight = LevelBars.height(for: level, idle: 2, max: height)
            let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: (height - barHeight) / 2, width: barWidth, height: barHeight)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1), style: .continuous)
        }
        return path
    }

    /// The bars on a shape layer that follows a live take on its own, so a new sample costs no SwiftUI update.
    final class BarsView: NSView {
        let bars = CAShapeLayer()
        private(set) var levels: [Float] = []
        private var ink: CGColor?
        private var feed: MeterFeed?
        private var following: Task<Void, Never>?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layer?.addSublayer(bars)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            following?.cancel()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            withoutActions(build)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            withoutActions(build)
        }

        func show(_ levels: [Float], ink: CGColor) {
            guard levels != self.levels || ink != self.ink else { return }
            self.levels = levels
            self.ink = ink
            withoutActions(build)
        }

        /// Each new sample, or under Reduce Motion four times a second, the bars take the take's levels without a SwiftUI update.
        func follow(_ feed: MeterFeed, ink: CGColor) {
            let restarts = feed != self.feed || following == nil
            self.feed = feed
            show(feed.levels(), ink: ink)
            guard restarts else { return }
            following?.cancel()
            let model = feed.model
            if let interval = feed.interval {
                following = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            } else {
                following = Task { [weak self] in
                    for await _ in Observations({ @MainActor in model.takeLevelTick }) {
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            }
        }

        func stopFollowing() {
            following?.cancel()
            following = nil
            feed = nil
        }

        private func showFeed() {
            guard let feed, let ink else { return }
            show(feed.levels(), ink: ink)
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }

        private func build() {
            bars.frame = bounds
            bars.contentsScale = window?.backingScaleFactor ?? 2
            bars.fillColor = ink
            bars.path = SessionMeter.barsPath(levels, height: bounds.height).cgPath
        }
    }
}

/// What the meter's layer reads from a live take between SwiftUI's updates.
struct MeterFeed: Equatable {
    let model: AppModel
    /// Under Reduce Motion the bars step this often instead of following each sample.
    let interval: TimeInterval?

    @MainActor
    func levels() -> [Float] {
        SessionMeter.levels(of: model)
    }

    nonisolated static func == (lhs: MeterFeed, rhs: MeterFeed) -> Bool {
        lhs.model === rhs.model && lhs.interval == rhs.interval
    }
}

private struct MeterLayer: NSViewRepresentable {
    let levels: [Float]
    let ink: Color
    let feed: MeterFeed?

    func makeNSView(context: Context) -> SessionMeter.BarsView {
        SessionMeter.BarsView()
    }

    func updateNSView(_ view: SessionMeter.BarsView, context: Context) {
        let ink = ink.resolve(in: context.environment).cgColor
        if let feed {
            view.follow(feed, ink: ink)
        } else {
            view.stopFollowing()
            view.show(levels, ink: ink)
        }
    }

    static func dismantleNSView(_ view: SessionMeter.BarsView, coordinator: ()) {
        view.stopFollowing()
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
