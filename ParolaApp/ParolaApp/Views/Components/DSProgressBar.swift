import SwiftUI

// `ProgressView(.linear)` hands its fill to NSProgressIndicator, which drops to grey while the window isn't key.
struct DSProgressBar: View {
    /// Nil while the run can't say how far along it is; the bar sweeps instead of filling.
    let value: Double?
    var fill: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepSpan = 0.3
    private static let sweepPeriod: Double = 1.4

    private var fraction: Double? { value.map { min(max($0, 0), 1) } }
    var resolvedFill: Color { fill ?? DS.Color.accent }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DS.Palette.subtleFill)
                if let fraction {
                    // The animation rides the fraction, not the bar's width: a layout change around a running
                    // job (the export pane opening) would otherwise interpolate the geometry too.
                    Capsule(style: .continuous)
                        .fill(resolvedFill)
                        .frame(width: geometry.size.width * fraction)
                        .animation(reduceMotion ? nil : DS.Motion.progress, value: fraction)
                } else {
                    sweep(across: geometry.size.width)
                }
            }
        }
        .frame(height: DS.Size.progressBarHeight)
        .clipped()
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
    private func sweep(across width: CGFloat) -> some View {
        let span = width * Self.sweepSpan
        if reduceMotion {
            Capsule(style: .continuous)
                .fill(resolvedFill.opacity(0.35))
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: Self.sweepPeriod) / Self.sweepPeriod
                Capsule(style: .continuous)
                    .fill(resolvedFill)
                    .frame(width: span)
                    .offset(x: (width + span) * phase - span)
            }
        }
    }
}
