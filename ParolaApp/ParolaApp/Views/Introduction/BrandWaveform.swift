import SwiftUI

/// The app icon's waveform at any size, tinted with the accent: the same nine bars and proportions, no rounded square behind them.
struct BrandWaveform: View {
    /// What sets the bars' heights: the icon at rest, or a clip's level envelope, one value per bar.
    enum Drive: Equatable {
        case breathing
        case levels([Float])
    }

    let side: CGFloat
    var drive: Drive = .breathing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    private static let fractions = AppIconArtwork.barFractions
    private static let centerIndex = fractions.count / 2

    /// A level's share of a bar's full height, with a floor so a silent mark is still the app's mark.
    nonisolated static func scale(level: Float) -> CGFloat {
        let value = Double(level)
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        return 0.35 + 0.65 * clamped
    }

    var body: some View {
        Group {
            switch drive {
            case .levels(let levels):
                levelBars(levels)
            case .breathing:
                if reduceMotion {
                    breathingBars(seconds: nil)
                } else {
                    TimelineView(.animation) { context in
                        breathingBars(seconds: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: usableWidth, height: usableHeight)
        .onAppear { risen = true }
        .accessibilityHidden(true)
    }

    private func breathingBars(seconds: TimeInterval?) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(Self.fractions.enumerated()), id: \.offset) { index, fraction in
                bar(height: barHeight(fraction) * (risen || reduceMotion ? 1 : 0.08))
                    .scaleEffect(y: breath(index: index, seconds: seconds), anchor: .center)
                    .animation(rise(index: index), value: risen)
            }
        }
    }

    private func levelBars(_ levels: [Float]) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(Self.fractions.enumerated()), id: \.offset) { index, fraction in
                bar(height: barHeight(fraction) * Self.scale(level: index < levels.count ? levels[index] : 0))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
    }

    private func bar(height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(DS.Color.accent)
            .frame(width: barWidth, height: height)
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
