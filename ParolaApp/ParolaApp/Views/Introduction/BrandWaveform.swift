import SwiftUI

/// The app icon's waveform, drawn at any size and tinted with the accent: the same nine bars, the
/// same proportions, no rounded square behind them.
struct BrandWaveform: View {
    let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    private static let fractions = AppIconArtwork.barFractions
    private static let centerIndex = fractions.count / 2

    var body: some View {
        Group {
            if reduceMotion {
                bars(seconds: nil)
            } else {
                TimelineView(.animation) { context in
                    bars(seconds: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: usableWidth, height: usableHeight)
        .onAppear { risen = true }
        .accessibilityHidden(true)
    }

    private func bars(seconds: TimeInterval?) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(Self.fractions.enumerated()), id: \.offset) { index, fraction in
                Capsule(style: .continuous)
                    .fill(DS.Color.accent)
                    .frame(width: barWidth, height: barHeight(fraction) * (risen || reduceMotion ? 1 : 0.08))
                    .scaleEffect(y: breath(index: index, seconds: seconds), anchor: .center)
                    .animation(rise(index: index), value: risen)
            }
        }
    }

    private var usableWidth: CGFloat { side * 0.56 }
    private var usableHeight: CGFloat { side * 0.72 }
    private var spacing: CGFloat { usableWidth / (CGFloat(Self.fractions.count) * 2) }

    private var barWidth: CGFloat {
        (usableWidth - spacing * CGFloat(Self.fractions.count - 1)) / CGFloat(Self.fractions.count)
    }

    private func barHeight(_ fraction: CGFloat) -> CGFloat {
        max(barWidth * 1.1, usableHeight * fraction)
    }

    private func rise(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        let stagger = Double(abs(index - Self.centerIndex)) * 0.06
        return .spring(response: 0.55, dampingFraction: 0.72).delay(stagger)
    }

    private func breath(index: Int, seconds: TimeInterval?) -> CGFloat {
        guard risen, let seconds else { return 1 }
        return 1 + 0.06 * sin(seconds * 1.4 + Double(index) * 0.5)
    }
}
