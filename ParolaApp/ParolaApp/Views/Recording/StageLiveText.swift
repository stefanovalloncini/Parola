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
            // The model's take, not the page's: a Stage on its way out keeps the take it was given, which is never over.
            isLive: model.takeIsRunning,
            caretBlinks: Self.caretBlinks(isOnScreen: isOnScreen, take: model.recording)
        )
    }

    /// Only while words can come in and someone can see them: paused, the caret holds still and the text doesn't redraw.
    nonisolated static func caretBlinks(isOnScreen: Bool, take: RecordingSession?) -> Bool {
        isOnScreen && take?.state == .recording
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

    /// The most of the run's text laid out, in UTF-8 bytes; the cut's step and its reach for a space leave over half of it, more than the column's four lines.
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
            isLive: model.takeTranscription != nil,
            caretBlinks: isOnScreen
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
    /// While more words can come; after that the last ones stay rather than the quiet line.
    var isLive = true
    /// Off while the page is out of sight, or the take can't add words, so the text isn't redrawn for the caret.
    let caretBlinks: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drawn = DrawnWords()

    private static let fade: CGFloat = 40

    struct Words: Equatable {
        let settled: String
        let partial: String
        var isEmpty: Bool { settled.isEmpty && partial.isEmpty }
    }

    /// The words on screen: the ones coming in, or once nothing more can come, the last that did; nil leaves room for the quiet line or nothing.
    nonisolated static func shown(_ now: Words, last: Words?, isLive: Bool) -> Words? {
        if !now.isEmpty { return now }
        return isLive ? nil : last
    }

    /// The words last drawn, noted as they are drawn: a copy kept by `onChange` can miss the newest when words come in faster than frames.
    @MainActor
    final class DrawnWords {
        private(set) var last: Words?

        func draw(_ words: Words?) -> Words? {
            if let words { last = words }
            return words
        }
    }

    var body: some View {
        let words = drawn.draw(Self.shown(Words(settled: settled, partial: partial), last: drawn.last, isLive: isLive))
        Group {
            if let words {
                LiveTail(
                    settled: words.settled,
                    partial: words.partial,
                    font: DS.Font.liveTranscriptStage,
                    lineSpacing: StageLiveText.lineSpacing,
                    blinks: caretBlinks
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: StageLiveText.width)
                // Both bounds, or a frame with only a maximum grows to the text's full height and nothing gets clipped.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                .animation(reduceMotion ? nil : DS.Motion.transcriptFollow, value: words.settled.count + words.partial.count)
                .clipped()
                .mask { topFade }
            } else if isLive {
                LiveQuietLine(text: quietLine)
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

    var body: some View {
        Text("\(Text(Self.attributed(settled: settled, partial: partial)))\(LiveCaret.placeholder)")
            .font(font)
            .lineSpacing(lineSpacing)
            .contentTransition(.identity)
            .accessibilityLabel(settled.isEmpty ? partial : settled + " " + partial)
            .liveCaret(font: font, blinks: blinks)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(settled: String, partial: String) -> AttributedString {
        var text = AttributedString(settled.isEmpty || partial.isEmpty ? settled : settled + " ")
        text.foregroundColor = DS.Color.primaryText
        var tail = AttributedString(partial)
        tail.foregroundColor = DS.Color.liveTail
        text.append(tail)
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
