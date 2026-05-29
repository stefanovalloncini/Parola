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
    private struct SegmentRun {
        let offsets: Range<Int>
        let baseColor: Color?
    }

    @Environment(AppModel.self) private var model
    @State private var hovering: Bool = false
    @State private var cursor: CGPoint = .zero
    @State private var attributedCache: AttributedString = AttributedString()
    @State private var segmentRuns: [TranscriptSegment.ID: SegmentRun] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?

    var body: some View {
        Text(attributedCache)
            .font(.system(size: model.transcriptCompact ? 14 : 18, weight: .regular))
            .lineSpacing(model.transcriptCompact ? 3 : 6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { rebuildAttributedText() }
            .onChange(of: model.transcriptVersion) { _, _ in rebuildAttributedText() }
            .onChange(of: model.currentSegmentID) { _, _ in applyHighlight() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    cursor = location
                case .ended:
                    hovering = false
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering, let seg = playTarget {
                    Button {
                        model.seek(to: seg)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Color.accent))
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                    .offset(x: cursor.x - 30, y: cursor.y - 11)
                }
            }
    }

    private var playTarget: TranscriptSegment? {
        guard let segments = model.transcript?.segments, !segments.isEmpty else { return nil }
        if let currentID = model.currentSegmentID,
           let seg = segments.first(where: { $0.id == currentID }) {
            return seg
        }
        return segments.first
    }

    private func rebuildAttributedText() {
        guard let transcript = model.transcript else {
            attributedCache = AttributedString()
            segmentRuns = [:]
            highlightedSegmentID = nil
            return
        }
        var attr = AttributedString()
        var runs: [TranscriptSegment.ID: SegmentRun] = [:]
        let segments = transcript.segments
        let useSpeakerColor = model.transcriptSpeakers.count >= 2
        var offset = 0

        for (idx, seg) in segments.enumerated() {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let baseColor: Color? = useSpeakerColor ? seg.speaker.map(DS.speakerColor(for:)) : nil
            var piece = AttributedString(body + (idx == segments.count - 1 ? "" : " "))
            if let baseColor { piece.foregroundColor = baseColor }
            let length = piece.characters.count
            runs[seg.id] = SegmentRun(offsets: offset..<offset + length, baseColor: baseColor)
            offset += length
            attr.append(piece)
        }
        attributedCache = attr
        segmentRuns = runs
        highlightedSegmentID = nil
        applyHighlight()
    }

    private func applyHighlight() {
        let nextID = model.currentSegmentID
        guard nextID != highlightedSegmentID else { return }
        if let previousID = highlightedSegmentID, let run = segmentRuns[previousID] {
            recolor(run, with: run.baseColor)
        }
        if let nextID, let run = segmentRuns[nextID] {
            recolor(run, with: DS.Color.accent)
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
