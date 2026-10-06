import Foundation

/// Turns a transcript, its summary or its translation into the sentence-sized units a reading speaks,
/// each anchored back to the text it came from. Pure and silent; safe to call off the main actor.
public enum ReadingScriptBuilder {
    static let paragraphPause = 0.35
    static let turnPause = 0.6
    static let sectionPause = 0.5
    static let maxUnitLength = 200
    static let minPieceLength = 40

    public static func build(_ source: ReadingSource, of transcript: Transcript, language: String?) -> [ReadingUnit] {
        switch source {
        case .transcript(let segmentID):
            return Self.transcript(transcript, from: segmentID, language: language)
        case .summary:
            guard let summary = transcript.summary else { return [] }
            return Self.summary(summary, language: language)
        case .translation(let target):
            guard let translation = transcript.translation, translation.targetLanguage == target else { return [] }
            return Self.translation(translation, of: transcript, language: language ?? target)
        }
    }

    /// Reads from `segmentID` on, or from the start when it is nil; an id the transcript doesn't have reads nothing.
    public static func transcript(
        _ transcript: Transcript,
        from segmentID: TranscriptSegment.ID? = nil,
        language: String?
    ) -> [ReadingUnit] {
        let pieces = steps(of: transcript, from: segmentID).map { step in
            Piece(anchor: .segment(step.segment.id), source: step.segment.text, boundary: step.boundary)
        }
        return units(of: script(joining: pieces), language: language)
    }

    /// Reads the translated segments in the transcript's order, pausing where the original turns or breaks a paragraph.
    public static func translation(
        _ translation: TranscriptTranslation,
        of transcript: Transcript,
        language: String
    ) -> [ReadingUnit] {
        var pieces: [Piece] = []
        var pending = Boundary.none
        for step in steps(of: transcript, from: nil) {
            pending = max(pending, step.boundary)
            guard let text = translation.segments[step.segment.id], text.contains(where: { !$0.isWhitespace }) else {
                continue
            }
            pieces.append(Piece(anchor: .translation(segmentID: step.segment.id), source: text, boundary: pending))
            pending = .none
        }
        return units(of: script(joining: pieces), language: language)
    }

    /// Reads the summary text without its markdown, then the chapter titles, then the action items; no headings are added.
    public static func summary(_ summary: Summary, language: String?) -> [ReadingUnit] {
        var lines: [SummaryLine] = []
        for (index, range) in paragraphs(in: summary.text).enumerated() {
            lines.append(SummaryLine(summary.text[range], anchor: .summaryParagraph(index), section: 0))
        }
        for chapter in summary.chapters {
            lines.append(SummaryLine(chapter.title[...], anchor: .chapter(chapter.id), section: 1, kind: .listItem))
        }
        for (index, item) in summary.actionItems.enumerated() {
            lines.append(SummaryLine(item[...], anchor: .actionItem(index), section: 2, kind: .listItem))
        }
        var script = AnchoredText()
        var previous: SummaryLine?
        for line in lines where line.hasText {
            if let previous, previous.section == line.section, previous.kind == .plain, line.kind == .plain {
                script.startRun(pauseBefore: paragraphPause)
            } else {
                script.startRun(pauseBefore: sectionPause)
            }
            line.append(to: &script)
            previous = line
        }
        return units(of: script, language: language)
    }

    /// The summary paragraphs `ReadingAnchor.summaryParagraph(_:)` counts: the non-blank lines of the summary text, as UTF-16 ranges.
    public static func summaryParagraphRanges(in summaryText: String) -> [NSRange] {
        paragraphs(in: summaryText).map { NSRange($0, in: summaryText) }
    }

    /// The text with heading, list and inline markdown markers removed and links reduced to their text.
    public static func strippingMarkdown(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(SummaryMarkdown.plainText)
            .joined(separator: "\n")
    }

    // MARK: - Transcript walk

    private enum Boundary: Int, Comparable {
        case none
        case paragraph
        case turn

        static func < (lhs: Boundary, rhs: Boundary) -> Bool { lhs.rawValue < rhs.rawValue }

        var pause: Double {
            switch self {
            case .none: 0
            case .paragraph: paragraphPause
            case .turn: turnPause
            }
        }
    }

    private struct Step {
        let segment: TranscriptSegment
        let boundary: Boundary
    }

    private static func steps(of transcript: Transcript, from segmentID: TranscriptSegment.ID?) -> [Step] {
        let segments = transcript.segments
        var startIndex = segments.startIndex
        if let segmentID {
            guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return [] }
            startIndex = index
        }
        let showsSpeakers = hasSeveralSpeakers(segments)
        var shownSpeaker = showsSpeakers
            ? segments[..<startIndex].reversed().lazy.filter(hasText).compactMap(speakerLabel).first
            : nil
        var lastEnd: Double?
        var steps: [Step] = []
        for segment in segments[startIndex...] where hasText(segment) {
            var boundary = Boundary.none
            if showsSpeakers, let label = speakerLabel(segment), label != shownSpeaker {
                boundary = .turn
                shownSpeaker = label
            } else if TranscriptParagraphRule.breaksParagraph(after: lastEnd, start: segment.start) {
                boundary = .paragraph
            }
            lastEnd = segment.end
            steps.append(Step(segment: segment, boundary: boundary))
        }
        return steps
    }

    private static func hasSeveralSpeakers(_ segments: [TranscriptSegment]) -> Bool {
        var first: String?
        for segment in segments where hasText(segment) {
            guard let label = speakerLabel(segment) else { continue }
            if let first, first != label { return true }
            first = label
        }
        return false
    }

    private static func hasText(_ segment: TranscriptSegment) -> Bool {
        segment.text.contains { !$0.isWhitespace }
    }

    private static func speakerLabel(_ segment: TranscriptSegment) -> String? {
        TranscriptParagraphRule.speakerLabel(for: segment.speaker)
    }

    // MARK: - Assembly

    private struct Piece {
        let anchor: ReadingAnchor
        let source: String
        let boundary: Boundary
    }

    private struct SummaryLine {
        let line: Substring
        let anchor: ReadingAnchor
        let section: Int
        let kind: SummaryMarkdown.LineKind
        let kept: [Range<String.Index>]

        init(_ line: Substring, anchor: ReadingAnchor, section: Int, kind: SummaryMarkdown.LineKind? = nil) {
            let stripped = SummaryMarkdown.strip(line)
            self.line = line
            self.anchor = anchor
            self.section = section
            self.kind = kind ?? stripped.kind
            self.kept = stripped.kept
        }

        var hasText: Bool {
            kept.contains { range in line[range].contains { !$0.isWhitespace } }
        }

        func append(to script: inout AnchoredText) {
            for range in kept {
                script.append(line[range], from: anchor, at: line.utf16.distance(from: line.startIndex, to: range.lowerBound))
            }
        }
    }

    private static func script(joining pieces: [Piece]) -> AnchoredText {
        var script = AnchoredText()
        for piece in pieces {
            let source = piece.source
            guard let body = SentenceSplitter.trimmed(source.startIndex..<source.endIndex, in: source) else { continue }
            if script.runs.isEmpty || piece.boundary != .none {
                script.startRun(pauseBefore: piece.boundary.pause)
            } else {
                script.appendSeparator(" ")
            }
            script.append(source[body], from: piece.anchor, at: source.utf16.distance(from: source.startIndex, to: body.lowerBound))
        }
        return script
    }

    private static func units(of script: AnchoredText, language: String?) -> [ReadingUnit] {
        let splitter = SentenceSplitter(language: language, maxLength: maxUnitLength, minLength: minPieceLength)
        return folded(splitter.drafts(of: script), language: language)
    }

    private static func folded(_ drafts: [DraftUnit], language: String?) -> [ReadingUnit] {
        var kept: [DraftUnit] = []
        var orphans: [ReadingUnit.Anchored] = []
        for var draft in drafts {
            if draft.isSpoken {
                if !orphans.isEmpty {
                    orphans.merge(draft.anchors)
                    draft.anchors = orphans
                    orphans = []
                }
                kept.append(draft)
            } else if !kept.isEmpty {
                kept[kept.count - 1].anchors.merge(draft.anchors)
                kept[kept.count - 1].pauseAfter = max(kept[kept.count - 1].pauseAfter, draft.pauseAfter)
            } else {
                orphans.merge(draft.anchors)
            }
        }
        return kept.enumerated().map { index, draft in
            ReadingUnit(
                id: index,
                text: draft.text,
                anchors: draft.anchors,
                language: language,
                pauseAfter: index == kept.count - 1 ? 0 : draft.pauseAfter
            )
        }
    }

    private static func paragraphs(in text: String) -> [Range<String.Index>] {
        text.split(whereSeparator: \.isNewline)
            .filter { $0.contains { !$0.isWhitespace } }
            .map { $0.startIndex..<$0.endIndex }
    }
}
