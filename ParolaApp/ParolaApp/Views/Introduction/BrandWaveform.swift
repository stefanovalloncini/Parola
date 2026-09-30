import SwiftUI

/// The app icon's waveform at any size, tinted with the accent: the same nine bars and proportions, no rounded square behind them.
struct BrandWaveform: View {
    /// What sets the bars' heights: the icon at rest, or a clip's level envelope, one value per bar.
    enum Drive: Equatable {
        case breathing
        case levels([Float])
    }

    let side: CGFloat
    var mark: AppIconArtwork.Mark = .pennino
    var drive: Drive = .breathing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    private static let fractions = AppIconArtwork.barFractions
    private static let centerIndex = fractions.count / 2

    private static let levelEase: Double = 0.08
    /// Settling back to the icon is a beat of its own, slower than tracking the next sample.
    private static let settleEase: Double = 0.25

    /// How many levels a drive has to carry, taken from the icon so the mark and the meter cannot disagree.
    nonisolated static let barCount = AppIconArtwork.barFractions.count

    /// How far behind the middle each bar out from it runs, so the mark ripples outward from the centre.
    nonisolated static let levelLagPerBar: Double = 0.05

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
        .frame(width: layout.width, height: layout.height)
        .onAppear { risen = true }
        .accessibilityHidden(true)
    }

    /// One row across both drives: a branch per drive would swap subtrees and snap the heights instead of easing them.
    private func bars(seconds: TimeInterval?) -> some View {
        HStack(spacing: layout.spacing) {
            ForEach(Self.fractions.indices, id: \.self) { index in
                if mark == .pennino && index == Self.centerIndex {
                    nib
                } else {
                    Capsule(style: .continuous)
                        .fill(DS.Color.accent)
                        .frame(width: layout.barWidth, height: height(index: index))
                        .scaleEffect(y: breath(index: index, seconds: seconds), anchor: .center)
                        .animation(rise(index: index), value: risen)
                }
            }
        }
        .animation(.easeOut(duration: drive == .breathing ? Self.settleEase : Self.levelEase), value: drive)
    }

    private var nib: some View {
        let frame = layout.nibFrame
        return NibShape()
            .fill(DS.Color.accent)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(y: risen || reduceMotion ? 1 : 0.08, anchor: .center)
            .animation(rise(index: Self.centerIndex), value: risen)
            .offset(y: frame.midY)
    }

    private func height(index: Int) -> CGFloat {
        let full = layout.barHeight(Self.fractions[index])
        switch drive {
        case .breathing:
            return full * (risen || reduceMotion ? 1 : 0.08)
        case .levels(let levels):
            return full * Self.scale(level: index < levels.count ? levels[index] : 0)
        }
    }

    private var layout: AppIconArtwork.Layout { AppIconArtwork.Layout(side: side, mark: mark) }

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

extension View {
    /// The bars Hello and the demo card hand to each other; both sites are sources, so whichever is on screen carries the frame.
    func brandBars(in namespace: Namespace.ID) -> some View {
        modifier(BrandBarsHandoff(namespace: namespace))
    }
}

private struct BrandBarsHandoff: ViewModifier {
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // An empty property set copies nothing from the source, so the bars stay put under reduce motion.
        content.matchedGeometryEffect(id: "brandBars", in: namespace, properties: reduceMotion ? [] : .frame)
    }
}

private struct NibShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(AppIconArtwork.nibPath(in: rect))
    }
}
