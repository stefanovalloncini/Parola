import AppKit
import SwiftUI

struct SkeletonLines: View {
    var count: Int = 4

    private static let lines = [
        "The meeting opened with a quick agenda review",
        "before the group walked through the numbers",
        "and the questions that came up were answered",
        "one by one until the discussion wound down",
        "closing with a short summary of the decisions",
        "and the follow-ups assigned for early next week",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            ForEach(0..<count, id: \.self) { index in
                Text(Self.lines[index % Self.lines.count])
                    .font(DS.Font.transcript)
                    .lineSpacing(DS.Spacing.transcriptLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .shimmering()
        .accessibilityHidden(true)
    }
}

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static let period: Double = 1.25
    /// The band's width, as a share of the lines'.
    nonisolated static let band: CGFloat = 0.5
    nonisolated static let key = "shimmer"

    static func highlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.22) : .black.opacity(0.07)
    }

    /// The band's leading edge runs from one and a half times the lines' width before them to as far past their start, evenly, again and again.
    nonisolated static func sweep(width: CGFloat, beginTime: CFTimeInterval) -> CABasicAnimation {
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -width * 1.5
        sweep.toValue = width * 1.5
        sweep.duration = period
        sweep.beginTime = beginTime
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        return sweep
    }

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                ShimmerLayer(highlight: Self.highlight(colorScheme))
                    .mask(content)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The band on a layer the render server moves, so no frame of the sweep runs in the app.
    final class SweepView: NSView {
        let band = CAGradientLayer()
        private var began: CFTimeInterval?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.locations = [0, 0.5, 1]
            layer?.addSublayer(band)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        var highlight: CGColor? {
            didSet {
                guard let highlight, highlight != oldValue else { return }
                // The highlight's own colour at no alpha, so the band fades out as SwiftUI's gradient to clear does rather than through black.
                let edge = highlight.copy(alpha: 0) ?? highlight
                withoutActions { band.colors = [edge, highlight, edge] }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let resized = newSize != frame.size
            super.setFrameSize(newSize)
            guard resized else { return }
            withoutActions {
                band.frame = CGRect(x: 0, y: 0, width: bounds.width * Shimmer.band, height: bounds.height)
            }
            run()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            withoutActions { band.contentsScale = window?.backingScaleFactor ?? 2 }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            run()
        }

        /// Starts from the band's first place when the lines first show, and keeps its beat through a resize.
        private func run() {
            band.removeAnimation(forKey: Shimmer.key)
            guard window != nil, bounds.width > 0 else { return }
            let began = began ?? band.convertTime(CACurrentMediaTime(), from: nil)
            self.began = began
            band.add(Shimmer.sweep(width: bounds.width, beginTime: began), forKey: Shimmer.key)
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }
    }
}

private struct ShimmerLayer: NSViewRepresentable {
    let highlight: Color

    func makeNSView(context: Context) -> Shimmer.SweepView {
        Shimmer.SweepView()
    }

    func updateNSView(_ view: Shimmer.SweepView, context: Context) {
        view.highlight = highlight.resolve(in: context.environment).cgColor
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
