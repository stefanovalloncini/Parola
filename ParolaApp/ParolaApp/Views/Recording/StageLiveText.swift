import SwiftUI
import ParolaCore

struct LiveParagraph: Identifiable, Equatable {
    let id: Int
    let speaker: String?
    var text: String
}

enum LiveParagraphs {
    /// The finished transcript's rule: a pause or a new speaker opens a paragraph.
    static func make(from segments: [TranscriptSegment]) -> [LiveParagraph] {
        var paragraphs: [LiveParagraph] = []
        var lastEnd: Double?
        for segment in segments {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let speaker = SegmentCard.speakerLabel(for: segment.speaker)
            let speakerChanged = paragraphs.last.map { $0.speaker != speaker } ?? true
            let pause = TranscriptParagraphs.breaksParagraph(after: lastEnd, start: segment.start)
            lastEnd = segment.end
            if paragraphs.isEmpty || pause || speakerChanged {
                paragraphs.append(LiveParagraph(id: segment.id, speaker: speaker, text: body))
            } else {
                paragraphs[paragraphs.count - 1].text += " " + body
            }
        }
        return paragraphs
    }
}

/// The Stage's teleprompter for a live take: the newest three or four lines in New York 24 pt, older ones fading out at the top.
struct StageLiveText: View {
    /// Off while the Stage is out of sight, so the caret stops blinking.
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model

    static let visibleLines = 4
    static let width: CGFloat = 720
    static let height: CGFloat = 156
    static let minHeight: CGFloat = 36
    static let lineSpacing: CGFloat = 7
    private static let recentSegments = 16

    var body: some View {
        StageTeleprompter(
            settled: Self.settledText(model.liveSegments),
            partial: model.livePartialText,
            quietLine: "Your transcript appears here as you speak",
            isOnScreen: isOnScreen
        )
    }

    /// The newest segments, broken where the finished transcript will break them, so nothing reflows when the take lands.
    static func settledText(_ segments: [TranscriptSegment]) -> String {
        LiveParagraphs.make(from: Array(segments.suffix(recentSegments)))
            .map(\.text)
            .joined(separator: "\n")
    }
}

/// The same teleprompter for a stopped take, reading the words its run sends back as it works through the file.
struct StageTakeText: View {
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model

    /// At most this many bytes of the run's text, in UTF-8, are laid out; never less than this minus one step, which still fills the column.
    nonisolated static let recentBytes = 900
    /// The cut moves from the front only in steps this long, so new words never re-break the lines already on screen.
    nonisolated static let cutStep = 300
    /// How far past a step the cut looks for a space; text with none that close, like Japanese, is cut between characters.
    nonisolated static let wordReach = 64

    var body: some View {
        StageTeleprompter(
            settled: Self.shown(model.takePartialText),
            partial: "",
            quietLine: Self.quietLine(streamsPartials: model.activeEngineStreamsPartials),
            isOnScreen: isOnScreen
        )
    }

    /// An engine that sends no words until it is done, like Parakeet, never promises them sooner.
    nonisolated static func quietLine(streamsPartials: Bool) -> LocalizedStringKey {
        streamsPartials ? "Transcript appears here as it comes in" : "Transcript appears when it's done"
    }

    /// The run hands back everything it has read so far; its newest stretch is found by byte offset, so hours of it cost no more than that stretch.
    nonisolated static func shown(_ text: String) -> String {
        let bytes = text.utf8
        let excess = bytes.count - recentBytes
        guard excess > 0 else { return text }
        var start = bytes.index(bytes.startIndex, offsetBy: (excess / cutStep + 1) * cutStep)
        if !isSpace(bytes[bytes.index(before: start)]) {
            let reach = bytes.index(start, offsetBy: wordReach, limitedBy: bytes.endIndex) ?? bytes.endIndex
            if let space = bytes[start..<reach].firstIndex(where: isSpace) { start = space }
        }
        while start < bytes.endIndex, isSpace(bytes[start]) { start = bytes.index(after: start) }
        while String.Index(start, within: text) == nil { start = bytes.index(after: start) }
        return String(text[start...])
    }

    private nonisolated static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }
}

/// Settled words, the unsettled tail and a caret, clipped to the newest lines with the older ones fading at the top.
struct StageTeleprompter: View {
    let settled: String
    let partial: String
    let quietLine: LocalizedStringKey
    let isOnScreen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let fade: CGFloat = 40

    var body: some View {
        Group {
            if settled.isEmpty, partial.isEmpty {
                LiveQuietLine(text: quietLine)
            } else {
                LiveTail(
                    settled: settled,
                    partial: partial,
                    font: DS.Font.liveTranscriptStage,
                    lineSpacing: StageLiveText.lineSpacing,
                    blinks: isOnScreen
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: StageLiveText.width)
                // Both bounds, or a frame with only a maximum grows to the text's full height and nothing gets clipped.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                .animation(reduceMotion ? nil : DS.Motion.transcriptFollow, value: settled.count + partial.count)
                .clipped()
                .mask { topFade }
            }
        }
        .padding(.horizontal, DS.Spacing.large)
    }

    @ViewBuilder
    private var topFade: some View {
        if reduceTransparency {
            Color.black
        } else {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(Self.fade, proxy.size.height / 2))
                    Color.black
                }
            }
        }
    }
}

/// Settled words in the primary ink, the unsettled tail in a grey that still clears 4.5:1, then the caret.
struct LiveTail: View {
    let settled: String
    let partial: String
    let font: Font
    let lineSpacing: CGFloat
    var blinks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()

    var body: some View {
        if blinks, !reduceMotion {
            TimelineView(.periodic(from: epoch, by: StreamingReveal.caretBlinkPeriod)) { context in
                let ticks = Int(context.date.timeIntervalSince(epoch) / StreamingReveal.caretBlinkPeriod)
                text(caretVisible: ticks.isMultiple(of: 2))
            }
        } else {
            text(caretVisible: true)
        }
    }

    private func text(caretVisible: Bool) -> some View {
        Text(Self.attributed(settled: settled, partial: partial, caretVisible: caretVisible))
            .font(font)
            .lineSpacing(lineSpacing)
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(settled.isEmpty ? partial : settled + " " + partial)
    }

    static func attributed(settled: String, partial: String, caretVisible: Bool) -> AttributedString {
        var text = AttributedString(settled.isEmpty || partial.isEmpty ? settled : settled + " ")
        text.foregroundColor = DS.Color.primaryText
        var tail = AttributedString(partial)
        tail.foregroundColor = DS.Color.liveTail
        text.append(tail)
        var caret = AttributedString("\u{258F}")
        caret.foregroundColor = DS.Color.accentInk.opacity(caretVisible ? 1 : 0)
        text.append(caret)
        return text
    }
}

struct LiveQuietLine: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
