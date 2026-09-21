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

    private static let levelEase: Double = 0.08
    /// Settling back to the icon is a beat of its own, slower than tracking the next sample.
    private static let settleEase: Double = 0.25

    /// A level's share of a bar's full height, with a floor so a silent mark is still the app's mark.
    nonisolated static func scale(level: Float) -> CGFloat {
        let value = Double(level)
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        return 0.35 + 0.65 * clamped
    }

    var body: some View {
        Group {
            if reduceMotion {
                bars(seconds: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    bars(seconds: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: usableWidth, height: usableHeight)
        .onAppear { risen = true }
        .accessibilityHidden(true)
    }

    /// One row across both drives: a branch per drive would swap subtrees and snap the heights instead of easing them.
    private func bars(seconds: TimeInterval?) -> some View {
        HStack(spacing: spacing) {
            ForEach(Self.fractions.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(DS.Color.accent)
                    .frame(width: barWidth, height: height(index: index))
                    .scaleEffect(y: breath(index: index, seconds: seconds), anchor: .center)
                    .animation(rise(index: index), value: risen)
            }
        }
        .animation(.easeOut(duration: drive == .breathing ? Self.settleEase : Self.levelEase), value: drive)
    }

    private func height(index: Int) -> CGFloat {
        let full = barHeight(Self.fractions[index])
        switch drive {
        case .breathing:
            return full * (risen || reduceMotion ? 1 : 0.08)
        case .levels(let levels):
            return full * Self.scale(level: index < levels.count ? levels[index] : 0)
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
        guard !reduceMotion, drive == .breathing else { return nil }
        let stagger = Double(abs(index - Self.centerIndex)) * 0.06
        return .spring(response: 0.55, dampingFraction: 0.72).delay(stagger)
    }

    private func breath(index: Int, seconds: TimeInterval?) -> CGFloat {
        guard drive == .breathing, risen, let seconds else { return 1 }
        return 1 + 0.06 * sin(seconds * 1.4 + Double(index) * 0.5)
    }
}
