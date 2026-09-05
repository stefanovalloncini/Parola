import SwiftUI

// `ProgressView(.linear)` hands its fill to NSProgressIndicator, which drops to system grey while the
// window is not key — most of a screen recording. Drawing the bar keeps the accent through the run.
struct DSProgressBar: View {
    let value: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { min(max(value, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DS.Palette.subtleFill)
                Capsule(style: .continuous)
                    .fill(DS.Color.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: DS.Size.progressBarHeight)
        .animation(reduceMotion ? nil : DS.Motion.progress, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}
