import SwiftUI

// `ProgressView(.linear)` hands its fill to NSProgressIndicator, which drops to system grey while the
// window is not key — most of a screen recording. Drawing the bar keeps the accent through the run.
struct DSProgressBar: View {
    /// Nil while the run can't say how far along it is; the bar sweeps instead of filling.
    let value: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepSpan = 0.3
    private static let sweepPeriod: Double = 1.4

    private var fraction: Double? { value.map { min(max($0, 0), 1) } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DS.Palette.subtleFill)
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(DS.Color.accent)
                        .frame(width: geometry.size.width * fraction)
                } else {
                    sweep(across: geometry.size.width)
                }
            }
        }
        .frame(height: DS.Size.progressBarHeight)
        .animation(reduceMotion ? nil : DS.Motion.progress, value: fraction)
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        guard let fraction else { return Text("In progress") }
        return Text(fraction.formatted(.percent.precision(.fractionLength(0))))
    }

    @ViewBuilder
    private func sweep(across width: CGFloat) -> some View {
        let span = width * Self.sweepSpan
        if reduceMotion {
            Capsule(style: .continuous)
                .fill(DS.Color.accent.opacity(0.35))
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: Self.sweepPeriod) / Self.sweepPeriod
                Capsule(style: .continuous)
                    .fill(DS.Color.accent)
                    .frame(width: span)
                    .offset(x: (width + span) * phase - span)
            }
        }
    }
}
