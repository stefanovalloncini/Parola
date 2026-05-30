import SwiftUI
import ParolaCore

struct TranscriptDetailView: View {
    let entryID: LibraryEntry.ID
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @State private var loaded: LoadedEntry?
    @State private var loadError: String?
    @State private var showingChat: Bool = false
    @State private var showingSpeakers: Bool = false
    @State private var query: String = ""
    @State private var currentMatchIndex: Int = 0
    @State private var selectedSpeaker: String?
    @State private var speakers: [String] = []
    @State private var filtered: [TranscriptSegment] = []
    @State private var matchIDs: [TranscriptSegment.ID] = []

    var body: some View {
        @Bindable var model = model
        return Group {
            if let loaded {
                VStack(spacing: 0) {
                    if speakers.count >= 2 {
                        SpeakerChipRow(
                            speakers: speakers,
                            selection: $selectedSpeaker
                        )
                    }
                    TranscriptScrollView(
                        segments: filtered,
                        query: trimmedQuery,
                        matchingIDs: matchIDs,
                        targetMatchID: targetMatchID(in: matchIDs)
                    )
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
                            Divider()
                            Button("YouTube Chapters") {
                                model.generateYouTubeChapters(for: loaded.document.transcript)
                            }
                            Button("Speakers…") { showingSpeakers = true }
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
                    ToolbarItemGroup(placement: .keyboard) {
                        if !matchIDs.isEmpty {
                            Text("\(currentMatchIndex + 1) / \(matchIDs.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                advanceMatch(total: matchIDs.count)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel(Text("Next match"))
                        }
                    }
                }
                .searchable(text: $query, prompt: "Search transcript")
                .onChange(of: query) { _, _ in
                    currentMatchIndex = 0
                    recomputeMatches()
                }
                .onChange(of: selectedSpeaker) { _, _ in
                    currentMatchIndex = 0
                    recomputeFiltered()
                }
                .sheet(isPresented: $showingChat) {
                    ChatSheet(entry: loaded.entry, transcript: loaded.document.transcript)
                        .environment(model)
                }
                .sheet(item: $model.promptOutput) { output in
                    PromptOutputSheet(output: output)
                }
                .sheet(isPresented: $showingSpeakers) {
                    SpeakersSheet(
                        entryID: loaded.entry.id,
                        transcript: loaded.document.transcript
                    ) { updated in
                        self.loaded = LoadedEntry(entry: loaded.entry, document: ParolaDocument(transcript: updated, audioURL: loaded.document.audioURL, manifest: loaded.document.manifest))
                        recomputeFiltered()
                    }
                    .environment(model)
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
                recomputeFiltered()
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

    private func recomputeFiltered() {
        guard let transcript = loaded?.document.transcript else {
            speakers = []
            filtered = []
            matchIDs = []
            return
        }
        speakers = transcript.uniqueSpeakers
        if let speaker = selectedSpeaker {
            filtered = transcript.segments.filter { $0.speaker == speaker }
        } else {
            filtered = transcript.segments
        }
        recomputeMatches()
    }

    private func recomputeMatches() {
        let q = trimmedQuery
        guard !q.isEmpty else {
            matchIDs = []
            return
        }
        matchIDs = filtered
            .filter { $0.text.range(of: q, options: .caseInsensitive) != nil }
            .map(\.id)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func targetMatchID(in matches: [TranscriptSegment.ID]) -> TranscriptSegment.ID? {
        guard !matches.isEmpty else { return nil }
        let safeIndex = min(max(0, currentMatchIndex), matches.count - 1)
        return matches[safeIndex]
    }

    private func advanceMatch(total: Int) {
        guard total > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % total
    }
}

private struct SpeakerChipRow: View {
    let speakers: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(label: "All", isSelected: selection == nil) { selection = nil }
                ForEach(speakers, id: \.self) { speaker in
                    Chip(label: speaker, isSelected: selection == speaker) {
                        selection = (selection == speaker) ? nil : speaker
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private struct Chip: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemFill))
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TranscriptScrollView: View {
    let segments: [TranscriptSegment]
    let query: String
    let matchingIDs: [TranscriptSegment.ID]
    let targetMatchID: TranscriptSegment.ID?
    @Environment(PlaybackController.self) private var playback

    private var matchSet: Set<TranscriptSegment.ID> { Set(matchingIDs) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { segment in
                        SegmentView(
                            segment: segment,
                            activeSegmentID: playback.currentSegmentID,
                            activeWordID: playback.currentWordID,
                            query: query,
                            isDimmed: !query.isEmpty && !matchSet.contains(segment.id)
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
            .onChange(of: targetMatchID) { _, id in
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
    let query: String
    let isDimmed: Bool

    nonisolated static func == (lhs: SegmentView, rhs: SegmentView) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.activeSegmentID == rhs.activeSegmentID
            && lhs.activeWordID == rhs.activeWordID
            && lhs.query == rhs.query
            && lhs.isDimmed == rhs.isDimmed
    }

    private var isActive: Bool { activeSegmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timestamp(segment.start))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let words = segment.words, !words.isEmpty {
                WordsView(words: words, activeWordID: activeWordID, query: query)
            } else {
                SegmentTextView(text: segment.text, start: segment.start, isActive: isActive, query: query)
            }
        }
        .opacity(isDimmed ? 0.4 : 1)
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
    let query: String
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        Text(highlighted(text: text.trimmingCharacters(in: .whitespaces), query: query))
            .onTapGesture { playback.seek(to: start) }
            .padding(6)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WordsView: View {
    let words: [WordTiming]
    let activeWordID: WordTiming.ID?
    let query: String

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(words) { word in
                WordChip(
                    word: word,
                    isActive: word.id == activeWordID,
                    isMatch: !query.isEmpty && word.word.range(of: query, options: .caseInsensitive) != nil
                )
            }
        }
    }
}

private struct WordChip: View, Equatable {
    let word: WordTiming
    let isActive: Bool
    let isMatch: Bool
    @Environment(PlaybackController.self) private var playback

    nonisolated static func == (lhs: WordChip, rhs: WordChip) -> Bool {
        lhs.word.id == rhs.word.id && lhs.isActive == rhs.isActive && lhs.isMatch == rhs.isMatch
    }

    var body: some View {
        Text(word.word)
            .fontWeight(isMatch ? .semibold : .regular)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onTapGesture { playback.seek(to: word.start) }
    }

    private var background: Color {
        if isMatch { return Color.yellow.opacity(0.55) }
        if isActive { return Color.accentColor.opacity(0.35) }
        return .clear
    }
}

private func highlighted(text: String, query: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard !query.isEmpty else { return attributed }
    var searchStart = text.startIndex
    while let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        if let attrRange = Range(range, in: attributed) {
            attributed[attrRange].backgroundColor = .yellow.opacity(0.55)
            attributed[attrRange].font = .body.bold()
        }
        searchStart = range.upperBound
    }
    return attributed
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
