import SwiftUI

/// Where a feature vignette's loop stands, as a fraction of its period. Pure, so the loop is testable without a view.
enum FeatureVignettePhase {
    static let period: Double = 4
    static let frameInterval: Double = 1.0 / 15.0

    static func phase(at time: Double, period: Double = FeatureVignettePhase.period) -> Double {
        guard period > 0 else { return 0 }
        let wrapped = time.truncatingRemainder(dividingBy: period)
        return (wrapped < 0 ? wrapped + period : wrapped) / period
    }

    /// 0 before `start`, 1 after `start + span`, linear between.
    static func ramp(_ phase: Double, from start: Double, span: Double) -> Double {
        guard span > 0 else { return phase >= start ? 1 : 0 }
        return min(1, max(0, (phase - start) / span))
    }

    static func ease(_ progress: Double) -> Double {
        let clamped = min(1, max(0, progress))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// One rise and fall over the window, peaking in the middle.
    static func pulse(_ phase: Double, from start: Double, span: Double) -> Double {
        sin(.pi * ramp(phase, from: start, span: span))
    }

    /// The loop opens on the settled frame and clears it, so phase 0 and phase 1 draw the same thing.
    static let resetSpan: Double = 0.1
}

enum FeatureVignetteKind {
    case transcribe
    case meetings
    case dictation
    case captions

    init?(symbol: String) {
        switch symbol {
        case DS.categorySymbol(for: .transcription): self = .transcribe
        case DS.categorySymbol(for: .meeting): self = .meetings
        case DS.categorySymbol(for: .dictation): self = .dictation
        case "captions.bubble.fill": self = .captions
        default: return nil
        }
    }
}

/// A looping sketch of one feature, sized to sit beside a feature card's text.
struct FeatureVignette: View {
    let kind: FeatureVignetteKind
    let hotkeyName: String

    static let size = CGSize(width: 132, height: 72)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = false

    var body: some View {
        loop
            .frame(width: Self.size.width, height: Self.size.height)
            .accessibilityHidden(true)
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
    }

    @ViewBuilder
    private var loop: some View {
        if reduceMotion {
            still(phase: 1)
        } else {
            TimelineView(.animation(minimumInterval: FeatureVignettePhase.frameInterval, paused: !isOnScreen)) { context in
                still(phase: FeatureVignettePhase.phase(at: context.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    @ViewBuilder
    private func still(phase: Double) -> some View {
        switch kind {
        case .transcribe: TranscribeVignette(phase: phase)
        case .meetings: MeetingVignette(phase: phase)
        case .dictation: DictationVignette(phase: phase, keyName: hotkeyName)
        case .captions: CaptionsVignette(phase: phase)
        }
    }
}

private struct TranscribeVignette: View {
    let phase: Double

    private static let lineWidths: [CGFloat] = [56, 42, 48]

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 18))
                .foregroundStyle(DS.Color.accent)
                .offset(y: -12 * (1 - FeatureVignettePhase.ease(drop)))
                .opacity(clearing * drop)
            VStack(alignment: .leading, spacing: DS.Spacing.snug) {
                ForEach(0..<Self.lineWidths.count, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(DS.Color.secondaryText.opacity(0.4))
                        .frame(width: Self.lineWidths[index] * fill(index), height: 4)
                        .frame(width: Self.lineWidths[index], alignment: .leading)
                        .opacity(clearing)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground(radius: DS.Radius.small)
    }

    private var clearing: Double {
        phase < FeatureVignettePhase.resetSpan ? 1 - phase / FeatureVignettePhase.resetSpan : 1
    }

    private var drop: Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return 1 }
        return FeatureVignettePhase.ramp(phase, from: 0.08, span: 0.14)
    }

    private func fill(_ index: Int) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return 1 }
        return FeatureVignettePhase.ease(
            FeatureVignettePhase.ramp(phase, from: 0.24 + Double(index) * 0.15, span: 0.12)
        )
    }
}

private struct MeetingVignette: View {
    let phase: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Zoom is running")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DS.Spacing.snug)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(DS.Palette.pillFill))
            HStack(spacing: DS.Spacing.snug) {
                Text("Record")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.onAccent)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Spacing.small)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(DS.Color.accent))
                    .scaleEffect(1 + 0.06 * FeatureVignettePhase.pulse(phase, from: 0.38, span: 0.24))
                Circle()
                    .fill(DS.Color.danger)
                    .frame(width: 6, height: 6)
                    .opacity(dot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var dot: Double {
        guard phase >= FeatureVignettePhase.resetSpan else {
            return 1 - phase / FeatureVignettePhase.resetSpan
        }
        return FeatureVignettePhase.ramp(phase, from: 0.67, span: 0.13)
    }
}

private struct DictationVignette: View {
    let phase: Double
    let keyName: String

    // Split once per process: the loop re-runs this view's body on every frame.
    private static let words: [String] = String(localized: "Send the notes")
        .split(separator: " ")
        .map(String.init)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(verbatim: keyName)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.snug)
                .padding(.vertical, 3)
                .frame(minWidth: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(press > 0.4 ? DS.Palette.pillFillHover : DS.Palette.pillFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .strokeBorder(DS.Palette.divider, lineWidth: 1)
                )
                .scaleEffect(1 - 0.08 * press)
            HStack(spacing: DS.Spacing.tight) {
                ForEach(0..<Self.words.count, id: \.self) { index in
                    // Dropped rather than hidden while it waits, so the caret sits against the last word that landed.
                    if word(index) > 0 {
                        Text(verbatim: Self.words[index])
                            .offset(y: 3 * (1 - landing(index)))
                            .opacity(word(index))
                    }
                }
                StreamingReveal.caret(visible: Int(phase * 6) % 2 == 0)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.primaryText)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var press: Double {
        FeatureVignettePhase.pulse(phase, from: 0.06, span: 0.2)
    }

    private func landing(_ index: Int) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return 1 }
        return FeatureVignettePhase.ease(
            FeatureVignettePhase.ramp(phase, from: 0.24 + Double(index) * 0.15, span: 0.12)
        )
    }

    private func word(_ index: Int) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else {
            return 1 - phase / FeatureVignettePhase.resetSpan
        }
        return landing(index)
    }
}

private struct CaptionsVignette: View {
    let phase: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Text("Listening")
                .font(DS.Font.caption)
                // The real captions panel paints its own dark scrim, so surface-derived colours read too dark here.
                .foregroundStyle(Color.white.opacity(0.55))
            ZStack(alignment: .topLeading) {
                caption("Words as they are spoken").opacity(first)
                caption("In a panel that stays on top").opacity(1 - first)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(DS.Font.heading)
            .foregroundStyle(Color.white)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The real panel crossfades a new caption in over 0.22 s; matched here, as a fraction of the loop.
    private static let crossfade = 0.22 / FeatureVignettePhase.period

    private var first: Double {
        if phase < 0.42 { return 1 }
        if phase < 0.42 + Self.crossfade { return 1 - (phase - 0.42) / Self.crossfade }
        if phase < 1 - Self.crossfade { return 0 }
        return (phase - (1 - Self.crossfade)) / Self.crossfade
    }
}
