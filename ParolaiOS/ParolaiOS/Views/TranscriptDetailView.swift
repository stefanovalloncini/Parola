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
    @State private var find = TranscriptFindState()
    @State private var selectedSpeaker: String?
    @State private var speakers: [String] = []
    @State private var filtered: [TranscriptSegment] = []
    @State private var transcriptIsEmpty = false

    var body: some View {
        @Bindable var model = model
        return Group {
            if let loaded {
                VStack(spacing: 0) {
                    if Self.showsSpeakerLabels(speakerCount: speakers.count) {
                        SpeakerChipRow(
                            speakers: speakers,
                            selection: $selectedSpeaker
                        )
                    }
                    if transcriptIsEmpty {
                        ContentUnavailableView(
                            "No Speech Detected",
                            systemImage: "waveform.slash",
                            description: Text("Parola didn't find any speech in this audio.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TranscriptScrollView(
                            segments: filtered,
                            showSpeaker: Self.showsSpeakerLabels(speakerCount: speakers.count),
                            query: find.appliedQuery,
                            matchingSet: find.matchSet,
                            targetMatchID: find.targetMatchID
                        )
                    }
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
                        ShareLink(
                            item: TranscriptShareItem(transcript: loaded.document.transcript),
                            preview: SharePreview(loaded.entry.title)
                        )
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        if !find.matchIDs.isEmpty {
                            Text("\(find.currentMatchIndex + 1) / \(find.matchIDs.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                find.advance()
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel(Text("Next match"))
                        }
                    }
                }
                .searchable(text: $query, prompt: "Search transcript")
                .task(id: query) {
                    await find.queryChanged(query, in: filtered)
                }
                .onChange(of: selectedSpeaker) { _, _ in
                    recomputeFiltered(resetsPosition: true)
                }
                .sheet(isPresented: $showingChat) {
                    ChatSheet(entry: loaded.entry, transcript: loaded.document.transcript) { updated in
                        self.loaded = LoadedEntry(entry: loaded.entry, document: ParolaDocument(transcript: updated, audioURL: loaded.document.audioURL, manifest: loaded.document.manifest))
                    }
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
                ContentUnavailableView(
                    "Couldn't Open Transcript",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onDisappear {
            playback.pause()
            playback.cancelIndexing()
        }
    }

    private func recomputeFiltered(resetsPosition: Bool = false) {
        guard let transcript = loaded?.document.transcript else {
            speakers = []
            filtered = []
            transcriptIsEmpty = false
            find.segmentsChanged([], resetsPosition: resetsPosition)
            return
        }
        speakers = transcript.uniqueSpeakers
        transcriptIsEmpty = !transcript.segments.contains { !Self.displayText($0.text).isEmpty }
        filtered = Self.visibleSegments(transcript.segments, speaker: selectedSpeaker)
        find.segmentsChanged(filtered, resetsPosition: resetsPosition)
    }

    static func visibleSegments(_ segments: [TranscriptSegment], speaker: String?) -> [TranscriptSegment] {
        segments.filter { segment in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let speaker else { return true }
            return segment.speaker == speaker
        }
    }

    static func showsSpeakerLabels(speakerCount: Int) -> Bool { speakerCount >= 2 }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func segmentTimecode(_ start: Double) -> String {
        Timecode.format(start)
    }

    static func speakerLabel(for speaker: String?) -> String? {
        TranscriptParagraphRule.speakerLabel(for: speaker)
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
    let showSpeaker: Bool
    let query: String
    let matchingSet: Set<TranscriptSegment.ID>
    let targetMatchID: TranscriptSegment.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { segment in
                        SegmentView(
                            segment: segment,
                            showSpeaker: showSpeaker,
                            query: query,
                            isDimmed: !query.isEmpty && !matchingSet.contains(segment.id)
                        )
                        .id(segment.id)
                    }
                }
                .padding()
            }
            .background { PlaybackScrollFollower(proxy: proxy) }
            .onChange(of: targetMatchID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct PlaybackScrollFollower: View {
    let proxy: ScrollViewProxy
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        Color.clear
            .onChange(of: playback.currentSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
    }
}

private struct SegmentView: View {
    let segment: TranscriptSegment
    let showSpeaker: Bool
    let query: String
    let isDimmed: Bool
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(TranscriptDetailView.segmentTimecode(segment.start))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if showSpeaker, let speaker = TranscriptDetailView.speakerLabel(for: segment.speaker) {
                    Text(speaker)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if playback.hasAudio {
                    PlayFromButton(segment: segment)
                }
            }
            if let words = segment.words, !words.isEmpty {
                ActiveWordsView(segmentID: segment.id, words: words, query: query)
            } else {
                SegmentTextView(segmentID: segment.id, text: segment.text, start: segment.start, query: query)
            }
        }
        .opacity(isDimmed ? 0.4 : 1)
    }
}

private struct PlayFromButton: View {
    let segment: TranscriptSegment
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        Button {
            playback.seek(to: segment.start)
        } label: {
            Image(systemName: "play.circle")
                .font(.body)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(playback.isActive(segment: segment.id) ? Color.accentColor : .secondary)
        .accessibilityLabel(Text("Play from \(TranscriptDetailView.segmentTimecode(segment.start))"))
    }
}

private struct ActiveWordsView: View {
    let segmentID: TranscriptSegment.ID
    let words: [WordTiming]
    let query: String
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        WordsView(words: words, activeWordID: playback.activeWordID(inSegment: segmentID), query: query)
    }
}

private struct SegmentTextView: View {
    let segmentID: TranscriptSegment.ID
    let text: String
    let start: Double
    let query: String
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        let isActive = playback.isActive(segment: segmentID)
        let label = Text(highlighted(text: TranscriptDetailView.displayText(text), query: query))
            .textSelection(.enabled)
            .padding(6)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        if playback.hasAudio {
            label
                .contentShape(Rectangle())
                .onTapGesture { playback.seek(to: start) }
        } else {
            label
        }
    }
}

struct WordsView: View {
    let words: [WordTiming]
    let activeWordID: WordTiming.ID?
    let query: String

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Self.mergeElidedWords(words)) { word in
                WordChip(
                    word: word,
                    isActive: activeWordID.map(word.wordIDs.contains) ?? false,
                    isMatch: TranscriptFind.contains(word.text, query: query)
                )
                .equatable()
            }
        }
    }

    struct MergedWord: Identifiable, Equatable {
        let id: WordTiming.ID
        let text: String
        let start: Double
        let wordIDs: Set<WordTiming.ID>
    }

    /// WhisperKit word timings split an elision into an apostrophe-leading tail ("l'altro" → ["l", "'altro"]); fold that tail back so the chips read as one word instead of "l" and "'altro" split by the layout gap.
    /// `nonisolated` because it is a pure function of its argument: `View` would otherwise infer the
    /// main actor onto it and every caller outside `body` would have to hop for nothing.
    nonisolated static func mergeElidedWords(_ words: [WordTiming]) -> [MergedWord] {
        var merged: [MergedWord] = []
        for word in words {
            if let last = merged.last, word.word.first == "'" || word.word.first == "\u{2019}" {
                merged[merged.count - 1] = MergedWord(
                    id: last.id,
                    text: last.text + word.word,
                    start: last.start,
                    wordIDs: last.wordIDs.union([word.id])
                )
            } else {
                merged.append(MergedWord(id: word.id, text: word.word, start: word.start, wordIDs: [word.id]))
            }
        }
        return merged
    }
}

private struct WordChip: View, Equatable {
    let word: WordsView.MergedWord
    let isActive: Bool
    let isMatch: Bool
    @Environment(PlaybackController.self) private var playback

    nonisolated static func == (lhs: WordChip, rhs: WordChip) -> Bool {
        lhs.word == rhs.word && lhs.isActive == rhs.isActive && lhs.isMatch == rhs.isMatch
    }

    var body: some View {
        let chip = Text(word.text)
            .fontWeight(isMatch ? .semibold : .regular)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        if playback.hasAudio {
            chip
                .contentShape(Rectangle())
                .onTapGesture { playback.seek(to: word.start) }
        } else {
            chip
        }
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
