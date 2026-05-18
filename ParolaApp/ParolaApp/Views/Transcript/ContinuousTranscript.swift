import SwiftUI
import ParolaCore

struct ContinuousTranscriptView: View {
    @EnvironmentObject var model: AppModel

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
    @EnvironmentObject var model: AppModel
    @State private var hovering: Bool = false
    @State private var cursor: CGPoint = .zero
    @State private var attributedCache: AttributedString = AttributedString()

    var body: some View {
        Text(attributedCache)
            .font(.system(size: model.transcriptCompact ? 14 : 18, weight: .regular))
            .lineSpacing(model.transcriptCompact ? 3 : 6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { rebuildAttributedText() }
            .onChange(of: model.transcriptVersion) { _, _ in rebuildAttributedText() }
            .onChange(of: model.currentSegmentID) { _, _ in rebuildAttributedText() }
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
            return
        }
        var attr = AttributedString()
        let currentID = model.currentSegmentID
        let segments = transcript.segments
        let useSpeakerColor = model.transcriptSpeakers.count >= 2

        for (idx, seg) in segments.enumerated() {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var piece = AttributedString(body + (idx == segments.count - 1 ? "" : " "))
            if seg.id == currentID {
                piece.foregroundColor = DS.Color.accent
            } else if useSpeakerColor, let speaker = seg.speaker {
                piece.foregroundColor = DS.speakerColor(for: speaker)
            }
            attr.append(piece)
        }
        attributedCache = attr
    }
}
