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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || pulsesFrom == nil)) { context in
            Circle()
                .fill(color)
                .frame(width: side, height: side)
                .opacity(Self.opacity(sincePulseStart: pulsesFrom.map { context.date.timeIntervalSince($0) }, reduceMotion: reduceMotion))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Still at full strength under Reduce Motion, or with nothing to pulse from.
    nonisolated static func opacity(sincePulseStart elapsed: TimeInterval?, reduceMotion: Bool) -> Double {
        guard let elapsed, !reduceMotion else { return 1 }
        return pulse(at: elapsed)
    }

    nonisolated static func pulse(at elapsed: TimeInterval) -> Double {
        let phase = elapsed - elapsed.rounded(.down)
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * phase))
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
