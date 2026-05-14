import SwiftUI
import ParolaCore

struct TranscriptDetailView: View {
    let entryID: LibraryEntry.ID
    @EnvironmentObject var model: AppModel
    @State private var loaded: LoadedEntry?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loaded {
                VStack(spacing: 0) {
                    TranscriptScrollView(loaded: loaded)
                    PlayerBar()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: loaded.document.transcript.text)
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .task(id: entryID) {
            do {
                let result = try await model.library.load(entryID)
                loaded = result
                model.playback.load(
                    audioURL: result.document.audioURL,
                    transcript: result.document.transcript
                )
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { model.playback.pause() }
    }
}

private struct TranscriptScrollView: View {
    let loaded: LoadedEntry
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(loaded.document.transcript.segments) { segment in
                        SegmentView(segment: segment)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.playback.currentSegmentID()) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct SegmentView: View {
    let segment: TranscriptSegment
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timestamp(segment.start))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let words = segment.words, !words.isEmpty {
                WordsView(words: words)
            } else {
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .onTapGesture { model.playback.seek(to: segment.start) }
                    .padding(6)
                    .background(highlightColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var isCurrent: Bool { model.playback.currentSegmentID() == segment.id }
    private var highlightColor: Color {
        isCurrent ? Color.accentColor.opacity(0.15) : Color.clear
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let m = (total % 3600) / 60
        let sec = total % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

private struct WordsView: View {
    let words: [WordTiming]
    @EnvironmentObject var model: AppModel

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(words) { word in
                Text(word.word)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(background(for: word))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .onTapGesture { model.playback.seek(to: word.start) }
            }
        }
    }

    private func background(for word: WordTiming) -> Color {
        model.playback.currentWord()?.id == word.id
            ? Color.accentColor.opacity(0.35)
            : Color.clear
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
