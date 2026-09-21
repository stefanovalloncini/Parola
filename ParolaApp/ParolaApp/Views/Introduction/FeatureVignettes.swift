import SwiftUI

/// Where a feature vignette's loop stands, as a fraction of its period. Pure, so the loop is testable without a view.
enum FeatureVignettePhase {
    static let period: Double = 4
    static let frameInterval: Double = 1.0 / 15.0

    /// Every loop opens on its settled frame and clears it over this much of the period, so phase 0 and phase 1 draw the same thing.
    static let resetSpan: Double = 0.1

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

    /// One rise and fall over the window, peaking in the middle and at rest on both sides.
    static func pulse(_ phase: Double, from start: Double, span: Double) -> Double {
        let progress = ramp(phase, from: start, span: span)
        guard progress > 0, progress < 1 else { return 0 }
        return sin(.pi * progress)
    }

    /// How much of the settled frame is still on screen while the loop clears it.
    static func clearing(_ phase: Double) -> Double {
        phase < resetSpan ? 1 - phase / resetSpan : 1
    }
}

enum FeatureVignetteKind: CaseIterable {
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

    /// Seconds into the loop each kind starts, so the four sketches never clear at the same moment.
    var phaseOffset: Double {
        switch self {
        case .transcribe: return 0
        case .meetings: return 1.1
        case .dictation: return 2.2
        case .captions: return 3.1
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
                still(phase: FeatureVignettePhase.phase(at: context.date.timeIntervalSinceReferenceDate + kind.phaseOffset))
            }
        }
    }

    @ViewBuilder
    private func still(phase: Double) -> some View {
        switch kind {
        case .transcribe: TranscribeVignette(frame: TranscribeFrame(phase: phase))
        case .meetings: MeetingVignette(frame: MeetingFrame(phase: phase))
        case .dictation: DictationVignette(frame: DictationFrame(phase: phase), phase: phase, keyName: hotkeyName)
        case .captions: CaptionsVignette(frame: CaptionsFrame(phase: phase))
        }
    }
}

/// One frame of the transcribe loop: a file glyph drops onto a card, then three lines of text fill in.
struct TranscribeFrame: Equatable {
    let glyphOpacity: Double
    let glyphOffset: Double
    let lineOpacity: Double
    let firstLine: Double
    let secondLine: Double
    let thirdLine: Double

    init(phase: Double) {
        let clearing = FeatureVignettePhase.clearing(phase)
        let drop = phase < FeatureVignettePhase.resetSpan
            ? 1
            : FeatureVignettePhase.ramp(phase, from: 0.08, span: 0.14)
        glyphOpacity = clearing * drop
        glyphOffset = -12 * (1 - FeatureVignettePhase.ease(drop))
        lineOpacity = clearing
        firstLine = Self.line(0, at: phase)
        secondLine = Self.line(1, at: phase)
        thirdLine = Self.line(2, at: phase)
    }

    func line(_ index: Int) -> Double {
        switch index {
        case 0: return firstLine
        case 1: return secondLine
        default: return thirdLine
        }
    }

    static func line(_ index: Int, at phase: Double) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return 1 }
        return FeatureVignettePhase.ease(
            FeatureVignettePhase.ramp(phase, from: 0.24 + Double(index) * 0.15, span: 0.12)
        )
    }
}

/// One frame of the meetings loop: the detection pill, a Record pill that beats once, a recording dot that arrives late.
struct MeetingFrame: Equatable {
    let pillScale: Double
    let dot: Double

    init(phase: Double) {
        pillScale = 1 + 0.06 * FeatureVignettePhase.pulse(phase, from: 0.38, span: 0.24)
        dot = phase < FeatureVignettePhase.resetSpan
            ? FeatureVignettePhase.clearing(phase)
            : FeatureVignettePhase.ramp(phase, from: 0.67, span: 0.13)
    }
}

/// One frame of the dictation loop: the key is held down while the words land one by one behind a blinking caret.
struct DictationFrame: Equatable {
    static let firstWord = 0.24
    static let lastWord = 0.7
    static let wordSpan = 0.12
    static let pressTravel = 0.08

    let press: Double
    let isHeld: Bool
    let caretVisible: Bool

    init(phase: Double) {
        // Down before the first word and up after the last: the card says "Hold a key and speak".
        press = min(
            FeatureVignettePhase.ease(FeatureVignettePhase.ramp(phase, from: 0.06, span: Self.pressTravel)),
            1 - FeatureVignettePhase.ease(FeatureVignettePhase.ramp(phase, from: Self.lastWord, span: Self.pressTravel))
        )
        isHeld = press > 0.5
        caretVisible = Int(phase * FeatureVignettePhase.period / StreamingReveal.caretBlinkPeriod) % 2 == 0
    }

    /// The stride comes from the word count, so a translation of any length still finishes by `lastWord`.
    static func landing(_ index: Int, of count: Int, at phase: Double) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return 1 }
        let stride = count > 1 ? (lastWord - wordSpan - firstWord) / Double(count - 1) : 0
        return FeatureVignettePhase.ease(
            FeatureVignettePhase.ramp(phase, from: firstWord + Double(index) * stride, span: wordSpan)
        )
    }

    static func word(_ index: Int, of count: Int, at phase: Double) -> Double {
        guard phase >= FeatureVignettePhase.resetSpan else { return FeatureVignettePhase.clearing(phase) }
        return landing(index, of: count, at: phase)
    }
}

/// One frame of the captions loop: the panel listens, then one caption arrives and holds. The real panel shows one or the other, never both.
struct CaptionsFrame: Equatable {
    /// Starts where the caption's own fade-out ends, so the panel is never blank for longer than a frame.
    static let listenFrom = FeatureVignettePhase.resetSpan
    static let listenUntil = 0.34
    static let captionFrom = 0.4
    static let fade = 0.06
    static let arrival = 0.1

    let listening: Double
    let caption: Double
    let captionOffset: Double

    init(phase: Double) {
        listening = phase >= Self.captionFrom
            ? 0
            : min(
                FeatureVignettePhase.ramp(phase, from: Self.listenFrom, span: Self.fade),
                1 - FeatureVignettePhase.ramp(phase, from: Self.listenUntil, span: Self.fade)
            )
        let arrived = phase < FeatureVignettePhase.resetSpan
            ? 1
            : FeatureVignettePhase.ease(FeatureVignettePhase.ramp(phase, from: Self.captionFrom, span: Self.arrival))
        // The real panel swaps its two states instantly, so the opacity takes the short fade and only the rise is eased.
        caption = phase < FeatureVignettePhase.resetSpan
            ? FeatureVignettePhase.clearing(phase)
            : FeatureVignettePhase.ramp(phase, from: Self.captionFrom, span: Self.fade)
        captionOffset = 3 * (1 - arrived)
    }
}

private struct TranscribeVignette: View {
    let frame: TranscribeFrame

    private static let lineWidths: [CGFloat] = [72, 54, 62]

    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 18

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(DS.Color.accent)
                .offset(y: frame.glyphOffset)
                .opacity(frame.glyphOpacity)
            VStack(alignment: .leading, spacing: DS.Spacing.snug) {
                ForEach(0..<Self.lineWidths.count, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(DS.Color.secondaryText.opacity(0.4))
                        .frame(width: Self.lineWidths[index], height: 4)
                        .scaleEffect(x: frame.line(index), anchor: .leading)
                        .opacity(frame.lineOpacity)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground(radius: DS.Radius.small)
    }
}

private struct MeetingVignette: View {
    let frame: MeetingFrame

    private static let detected = String(localized: "Zoom is running")
    private static let record = String(localized: "Record")

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(verbatim: Self.detected)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DS.Spacing.snug)
                .padding(.vertical, DS.Spacing.tight)
                .background(Capsule(style: .continuous).fill(DS.Palette.pillFill))
            HStack(spacing: DS.Spacing.snug) {
                Text(verbatim: Self.record)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.onAccent)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Spacing.small)
                    .padding(.vertical, DS.Spacing.tight)
                    .background(Capsule(style: .continuous).fill(DS.Color.accent))
                    .scaleEffect(frame.pillScale)
                Circle()
                    .fill(DS.Color.danger)
                    .frame(width: 6, height: 6)
                    .opacity(frame.dot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct DictationVignette: View {
    let frame: DictationFrame
    // The words' own progress depends on how many the phrase has, which only this view knows, so it keeps the phase too.
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
                .padding(.vertical, DS.Spacing.tight)
                .frame(minWidth: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(frame.isHeld ? DS.Color.accentWash : DS.Palette.pillFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .strokeBorder(frame.isHeld ? DS.Color.accent : DS.Palette.divider, lineWidth: frame.isHeld ? 2 : 1)
                )
                .scaleEffect(1 - 0.08 * frame.press)
            HStack(spacing: DS.Spacing.tight) {
                ForEach(0..<Self.words.count, id: \.self) { index in
                    // Dropped rather than hidden while it waits, so the caret sits against the last word that landed.
                    let opacity = DictationFrame.word(index, of: Self.words.count, at: phase)
                    if opacity > 0 {
                        Text(verbatim: Self.words[index])
                            .offset(y: 3 * (1 - DictationFrame.landing(index, of: Self.words.count, at: phase)))
                            .opacity(opacity)
                    }
                }
                StreamingReveal.caret(visible: frame.caretVisible)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.primaryText)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct CaptionsVignette: View {
    let frame: CaptionsFrame

    private static let listening = String(localized: "Listening")
    private static let line = String(localized: "Words as they are spoken")

    var body: some View {
        ZStack {
            HStack(spacing: DS.Spacing.snug) {
                Image(systemName: "waveform")
                Text(verbatim: Self.listening)
            }
            .font(DS.Font.caption)
            // The real captions panel paints its own dark scrim, so surface-derived colours read too dark here.
            .foregroundStyle(Color.white.opacity(0.55))
            .opacity(frame.listening)
            Text(verbatim: Self.line)
                .font(DS.Font.heading)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: frame.captionOffset)
                .opacity(frame.caption)
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
