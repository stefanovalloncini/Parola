import AppKit
import SwiftUI

// `ProgressView(.linear)` hands its fill to NSProgressIndicator, which drops to grey while the window isn't key.
struct DSProgressBar: View {
    /// Nil while the run can't say how far along it is; the bar sweeps instead of filling.
    let value: Double?
    var fill: Color? = nil
    var height: CGFloat = DS.Size.progressBarHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let sweepSpan = 0.3
    nonisolated static let sweepPeriod: Double = 1.4
    nonisolated static let sweepKey = "sweep"

    private var fraction: Double? { value.map { min(max($0, 0), 1) } }
    var resolvedFill: Color { fill ?? DS.Color.accent }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DS.Palette.subtleFill)
                if let fraction {
                    // The animation rides the fraction, not the bar's width, so a layout change can't interpolate the geometry too.
                    Capsule(style: .continuous)
                        .fill(resolvedFill)
                        .frame(width: geometry.size.width * fraction)
                        .animation(reduceMotion ? nil : DS.Motion.progress, value: fraction)
                } else {
                    sweep
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        guard let fraction else { return Text("In progress") }
        return Text(AppFormat.percent(fraction))
    }

    @ViewBuilder
    private var sweep: some View {
        if reduceMotion {
            Capsule(style: .continuous)
                .fill(resolvedFill.opacity(0.35))
        } else {
            SweepLayer(fill: resolvedFill)
        }
    }

    /// Every sweep on screen keeps the same beat, counted from the reference date: the layer time at which this one's loop began.
    nonisolated static func sweepBegin(now: Date, layerTime: CFTimeInterval) -> CFTimeInterval {
        layerTime - now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepPeriod)
    }

    /// The bar's leading edge runs from a span before the track to its end, at an even pace, again and again.
    nonisolated static func sweepAnimation(width: CGFloat, beginTime: CFTimeInterval) -> CABasicAnimation {
        let span = width * sweepSpan
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -span
        sweep.toValue = width
        sweep.duration = sweepPeriod
        sweep.beginTime = beginTime
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        return sweep
    }

    /// The sweep on a layer the render server moves, so no frame of it runs in the app.
    final class SweepView: NSView {
        let bar = CAShapeLayer()
        private let track = CAShapeLayer()
        private var wakeObserver: (any NSObjectProtocol)?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layer?.mask = track
            layer?.addSublayer(bar)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        var fill: CGColor? {
            get { bar.fillColor }
            set { withoutActions { bar.fillColor = newValue } }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let resized = newSize != frame.size
            super.setFrameSize(newSize)
            guard resized else { return }
            build()
            run()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            build()
        }

        private func build() {
            withoutActions {
                let scale = window?.backingScaleFactor ?? 2
                track.contentsScale = scale
                bar.contentsScale = scale
                track.frame = bounds
                track.path = Capsule(style: .continuous).path(in: bounds).cgPath
                bar.frame = CGRect(x: 0, y: 0, width: bounds.width * DSProgressBar.sweepSpan, height: bounds.height)
                bar.path = Capsule(style: .continuous).path(in: bar.bounds).cgPath
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWake()
            run()
        }

        // Core Animation's clock stands still while the Mac sleeps, so a wake starts the loop again on the beat.
        private func observeWake() {
            let center = NSWorkspace.shared.notificationCenter
            if let wakeObserver { center.removeObserver(wakeObserver) }
            wakeObserver = nil
            guard window != nil else { return }
            wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
        }

        private func run() {
            bar.removeAnimation(forKey: DSProgressBar.sweepKey)
            guard window != nil, bounds.width > 0 else { return }
            let begin = DSProgressBar.sweepBegin(now: Date(), layerTime: bar.convertTime(CACurrentMediaTime(), from: nil))
            bar.add(DSProgressBar.sweepAnimation(width: bounds.width, beginTime: begin), forKey: DSProgressBar.sweepKey)
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }
    }
}

private struct SweepLayer: NSViewRepresentable {
    let fill: Color

    func makeNSView(context: Context) -> DSProgressBar.SweepView {
        DSProgressBar.SweepView()
    }

    func updateNSView(_ view: DSProgressBar.SweepView, context: Context) {
        view.fill = fill.resolve(in: context.environment).cgColor
    }
}
