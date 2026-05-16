import SwiftUI
import ParolaCore

struct TranscriptDetailView: View {
    let entryID: LibraryEntry.ID
    @EnvironmentObject var model: AppModel
    @Environment(PlaybackController.self) private var playback
    @State private var loaded: LoadedEntry?
    @State private var loadError: String?
    @State private var showingChat: Bool = false

    var body: some View {
        Group {
            if let loaded {
                VStack(spacing: 0) {
                    TranscriptScrollView(loaded: loaded)
                    if playback.hasAudio {
                        PlayerBar()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(Prompt.builtIns) { prompt in
                                Button(prompt.name) {
                                    model.runPrompt(prompt, on: loaded.document.transcript)
                                }
                            }
                        } label: {
                            if model.isRunningPrompt {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                        }
                        .disabled(model.isRunningPrompt)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingChat = true } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: loaded.document.transcript.text)
                    }
                }
                .sheet(isPresented: $showingChat) {
                    ChatSheet(entry: loaded.entry, transcript: loaded.document.transcript)
                        .environmentObject(model)
                }
                .sheet(item: $model.promptOutput) { output in
                    PromptOutputSheet(output: output)
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
                playback.load(
                    audioURL: result.document.audioURL,
                    transcript: result.document.transcript
                )
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { playback.pause() }
    }
}

private struct TranscriptScrollView: View {
    let loaded: LoadedEntry
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(loaded.document.transcript.segments) { segment in
                        SegmentView(
                            segment: segment,
                            activeSegmentID: playback.currentSegmentID,
                            activeWordID: playback.currentWordID
                        )
                        .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: playback.currentSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct SegmentView: View, Equatable {
    let segment: TranscriptSegment
    let activeSegmentID: TranscriptSegment.ID?
    let activeWordID: WordTiming.ID?

    nonisolated static func == (lhs: SegmentView, rhs: SegmentView) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.activeSegmentID == rhs.activeSegmentID
            && lhs.activeWordID == rhs.activeWordID
    }

    private var isActive: Bool { activeSegmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timestamp(segment.start))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let words = segment.words, !words.isEmpty {
                WordsView(words: words, activeWordID: activeWordID)
            } else {
                SegmentTextView(text: segment.text, start: segment.start, isActive: isActive)
            }
        }
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

private struct SegmentTextView: View {
    let text: String
    let start: Double
    let isActive: Bool
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespaces))
            .onTapGesture { playback.seek(to: start) }
            .padding(6)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WordsView: View {
    let words: [WordTiming]
    let activeWordID: WordTiming.ID?

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(words) { word in
                WordChip(word: word, isActive: word.id == activeWordID)
            }
        }
    }
}

private struct WordChip: View, Equatable {
    let word: WordTiming
    let isActive: Bool
    @Environment(PlaybackController.self) private var playback

    nonisolated static func == (lhs: WordChip, rhs: WordChip) -> Bool {
        lhs.word.id == rhs.word.id && lhs.isActive == rhs.isActive
    }

    var body: some View {
        Text(word.word)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(isActive ? Color.accentColor.opacity(0.35) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onTapGesture { playback.seek(to: word.start) }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x + size.width > bounds.maxX, x > bounds.minX {
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
