import SwiftUI
import ParolaCore

struct ContinuousTranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ContinuousParagraph()
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.large)
                Spacer(minLength: 0)
            }
        }
    }
}

struct ContinuousParagraph: View {
    struct SegmentRun {
        let offsets: Range<Int>
        let baseColor: Color?
    }

    @Environment(AppModel.self) private var model
    @State private var attributedCache: AttributedString = AttributedString()
    @State private var segmentRuns: [TranscriptSegment.ID: SegmentRun] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?
    @ScaledMetric(relativeTo: .body) private var compactSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var comfortableSize: CGFloat = 18

    var body: some View {
        Text(attributedCache)
            .font(.system(size: model.transcriptCompact ? compactSize : comfortableSize, weight: .regular))
            .lineSpacing(model.transcriptCompact ? 3 : 6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { rebuildAttributedText() }
            .onChange(of: model.transcriptVersion) { _, _ in rebuildAttributedText() }
            .onChange(of: model.currentSegmentID) { _, _ in applyHighlight() }
    }

    private func rebuildAttributedText() {
        guard let transcript = model.transcript else {
            attributedCache = AttributedString()
            segmentRuns = [:]
            highlightedSegmentID = nil
            return
        }
        let built = Self.paragraph(
            segments: transcript.segments,
            useSpeakerColor: model.transcriptSpeakers.count >= 2
        )
        attributedCache = built.text
        segmentRuns = built.runs
        highlightedSegmentID = nil
        applyHighlight()
    }

    static func paragraph(
        segments: [TranscriptSegment],
        useSpeakerColor: Bool
    ) -> (text: AttributedString, runs: [TranscriptSegment.ID: SegmentRun]) {
        var attr = AttributedString()
        var runs: [TranscriptSegment.ID: SegmentRun] = [:]
        var offset = 0
        var shownSpeaker: String?
        for seg in segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let baseColor: Color? = useSpeakerColor ? seg.speaker.map(DS.speakerColor(for:)) : nil
            if let label = useSpeakerColor ? SegmentCard.speakerLabel(for: seg.speaker) : nil,
               label != shownSpeaker {
                if !attr.characters.isEmpty {
                    let separator = AttributedString("\n\n")
                    offset += separator.characters.count
                    attr.append(separator)
                }
                var heading = AttributedString(label + "\n")
                heading.foregroundColor = baseColor
                heading.inlinePresentationIntent = .stronglyEmphasized
                offset += heading.characters.count
                attr.append(heading)
                shownSpeaker = label
            }
            let startsLine = attr.characters.isEmpty || attr.characters.last == "\n"
            var piece = AttributedString(startsLine ? body : " " + body)
            if let baseColor { piece.foregroundColor = baseColor }
            let length = piece.characters.count
            runs[seg.id] = SegmentRun(offsets: offset..<offset + length, baseColor: baseColor)
            offset += length
            attr.append(piece)
        }
        return (attr, runs)
    }

    private func applyHighlight() {
        let nextID = model.currentSegmentID
        guard nextID != highlightedSegmentID else { return }
        if let previousID = highlightedSegmentID, let run = segmentRuns[previousID] {
            recolor(run, with: run.baseColor)
        }
        if let nextID, let run = segmentRuns[nextID] {
            recolor(run, with: DS.Color.highlight)
        }
        highlightedSegmentID = nextID
    }

    private func recolor(_ run: SegmentRun, with color: Color?) {
        let chars = attributedCache.characters
        guard
            let lo = chars.index(chars.startIndex, offsetBy: run.offsets.lowerBound, limitedBy: chars.endIndex),
            let hi = chars.index(chars.startIndex, offsetBy: run.offsets.upperBound, limitedBy: chars.endIndex)
        else { return }
        attributedCache[lo..<hi].foregroundColor = color
    }
}
