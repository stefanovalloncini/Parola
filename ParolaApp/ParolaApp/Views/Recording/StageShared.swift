import AppKit
import SwiftUI

/// The take's time in whole seconds of capture, pauses left out; it stands still while the take pauses or finishes.
struct StageClock: View {
    let take: RecordingSession
    let font: Font
    var rolls = false
    /// Off while the Stage is out of sight, so the clock stops ticking.
    var ticks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func text(seconds: Int) -> String {
        AppFormat.elapsed(TimeInterval(seconds))
    }

    static let roll = Animation.easeOut(duration: 0.2)
    /// A short climb, as `numericText` rolls: the new digit rises into place as the old one rises out.
    static let rollTransition = AnyTransition.asymmetric(
        insertion: .offset(y: 18).combined(with: .opacity),
        removal: .offset(y: -18).combined(with: .opacity)
    )

    /// Each character with its place counted from the right, so a digit keeps its identity as the clock grows and only the ones that change roll.
    nonisolated static func places(_ text: String) -> [(place: Int, character: Character)] {
        text.enumerated().map { (text.count - 1 - $0.offset, $0.element) }
    }

    var body: some View {
        if ticks, take.state == .recording, let origin = take.clockOrigin {
            TimelineView(.periodic(from: origin, by: 1)) { context in
                face(at: context.date)
            }
        } else {
            face(at: Date())
        }
    }

    private func face(at date: Date) -> some View {
        let seconds = Int(take.elapsed(at: date))
        let rolling = rolls && !reduceMotion
        return HStack(spacing: 0) {
            ForEach(Self.places(Self.text(seconds: seconds)), id: \.place) { place in
                // Slid and faded rather than numericText, whose blur is drawn on the CPU every frame at many times the cost.
                ZStack {
                    Text(verbatim: String(place.character))
                        .id(place.character)
                        .transition(rolling ? Self.rollTransition : .identity)
                }
                .animation(rolling ? Self.roll : nil, value: place.character)
            }
        }
        .font(font)
        // Shrinks with its frame as a landing carries it into the media bar's duration.
        .lineLimit(1)
        .minimumScaleFactor(0.1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording time")
        .accessibilityValue(AppFormat.spokenDuration(seconds: seconds))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension RecordingSession {
    /// When the take's clock read 0:00, counting its pauses as time it never ran; the clock ticks on whole seconds from here.
    var clockOrigin: Date? {
        startedAt?.addingTimeInterval(pausedTotal)
    }
}

/// The recording light: full strength as each second of the take turns over, easing to 35 % halfway through it.
struct RecDot: View {
    var color: Color = DS.Color.recordingFill
    var side: CGFloat = 8
    var pulsesFrom: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let pulseKey = "pulse"

    var body: some View {
        Group {
            if let origin = Self.pulseOrigin(pulsesFrom, reduceMotion: reduceMotion) {
                PulsingLight(color: color, origin: origin)
            } else {
                Circle()
                    .fill(color)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Nil while the light holds still at full strength: under Reduce Motion, or with nothing to pulse from.
    nonisolated static func pulseOrigin(_ origin: Date?, reduceMotion: Bool) -> Date? {
        reduceMotion ? nil : origin
    }

    nonisolated static func pulse(at elapsed: TimeInterval) -> Double {
        let phase = elapsed - elapsed.rounded(.down)
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }

    /// When the take's current second began, in a layer's time, so a light built at any moment pulses in step with the take.
    nonisolated static func pulseBegin(origin: Date, now: Date, layerTime: CFTimeInterval) -> CFTimeInterval {
        let elapsed = now.timeIntervalSince(origin)
        return layerTime - (elapsed - elapsed.rounded(.down))
    }

    static func pulseAnimation(beginTime: CFTimeInterval) -> CAKeyframeAnimation {
        let steps = 60
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0...steps).map { pulse(at: Double($0) / Double(steps)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = 1
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A layer the render server pulses, so the app does no work for the light from frame to frame.
    final class LightView: NSView {
        let dot = CALayer()
        private var origin: Date?
        private var wakeObserver: (any NSObjectProtocol)?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            dot.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            dot.frame = CGRect(origin: .zero, size: newSize)
            dot.cornerRadius = min(newSize.width, newSize.height) / 2
        }

        // A click on the light belongs to the button it sits in.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWake()
            pulse()
        }

        // Core Animation's clock stands still while the Mac sleeps and the take's doesn't, so a wake starts the loop again in step.
        private func observeWake() {
            let center = NSWorkspace.shared.notificationCenter
            if let wakeObserver { center.removeObserver(wakeObserver) }
            wakeObserver = nil
            guard window != nil else { return }
            wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pulse() }
            }
        }

        func show(_ color: CGColor, pulsingFrom origin: Date) {
            dot.backgroundColor = color
            guard origin != self.origin else { return }
            self.origin = origin
            pulse()
        }

        private func pulse() {
            dot.removeAnimation(forKey: RecDot.pulseKey)
            guard window != nil, let origin else { return }
            let begin = RecDot.pulseBegin(origin: origin, now: Date(), layerTime: dot.convertTime(CACurrentMediaTime(), from: nil))
            dot.add(RecDot.pulseAnimation(beginTime: begin), forKey: RecDot.pulseKey)
        }
    }
}

private struct PulsingLight: NSViewRepresentable {
    let color: Color
    let origin: Date

    func makeNSView(context: Context) -> RecDot.LightView {
        RecDot.LightView()
    }

    func updateNSView(_ view: RecDot.LightView, context: Context) {
        view.show(color.resolve(in: context.environment).cgColor, pulsingFrom: origin)
    }
}

/// Whether the window this sits in is on screen: false while it is minimized, hidden with the app, covered, or on another Space.
struct WindowShownReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    nonisolated static func shows(isVisible: Bool, isMiniaturized: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && !isMiniaturized && occlusion.contains(.visible)
    }

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [any NSObjectProtocol] = []
        private var reported: Bool?

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            // A view joins its window inside SwiftUI's update, which must not change the Stage's state.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            let shown = WindowShownReader.shows(
                isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, occlusion: window.occlusionState
            )
            guard shown != reported else { return }
            reported = shown
            onChange?(shown)
        }
    }
}
