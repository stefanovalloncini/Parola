import SwiftUI
import AVKit
import ParolaCore

struct TranscriptPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            transcriptList
                .frame(minWidth: 320)

            playerColumn
                .frame(minWidth: 280)
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let t = model.transcript {
                        ForEach(t.segments) { seg in
                            SegmentRow(segment: seg, isCurrent: seg.id == model.currentSegmentID)
                                .id(seg.id)
                                .onTapGesture { model.seek(to: seg) }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.currentSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var playerColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player = model.player {
                VideoPlayer(player: player)
                    .frame(height: 200)
                    .background(Color.black.opacity(0.05))
            }

            if let t = model.transcript {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language: \(t.language.uppercased())")
                    Text("Model: \(t.modelName)")
                    Text("\(t.segments.count) segments")
                    if let d = t.durationSeconds {
                        Text(String(format: "Duration: %.1fs", d))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }

            Spacer()

            HStack {
                Menu("Export") {
                    Button("As Plain Text…") { model.exportRequest(.txt) }
                    Button("As SubRip (.srt)…") { model.exportRequest(.srt) }
                    Button("As WebVTT (.vtt)…") { model.exportRequest(.vtt) }
                    Button("As JSON…") { model.exportRequest(.json) }
                }
                .fixedSize()

                Button("Copy") {
                    if let t = model.transcript {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t.text, forType: .string)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if isCurrent, let words = segment.words, !words.isEmpty {
            karaoke(words: words)
        } else {
            TextField(
                "",
                text: Binding(
                    get: { segment.text },
                    set: { model.editSegment(id: segment.id, newText: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...20)
        }
    }

    private func karaoke(words: [WordTiming]) -> Text {
        words.reduce(Text("")) { acc, word in
            let highlighted = word.id == model.currentWordID
            var piece = Text(word.word + " ")
            if highlighted {
                piece = piece.bold().foregroundColor(.accentColor)
            }
            return acc + piece
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
