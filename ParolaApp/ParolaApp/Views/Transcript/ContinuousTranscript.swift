import SwiftUI
import ParolaCore

struct ContinuousTranscriptView: View {
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ContinuousChunks(scrollProxy: proxy)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, DS.Spacing.large)
                        .padding(.vertical, DS.Spacing.large)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct ContinuousChunks: View {
    struct SegmentRun {
        let offsets: Range<Int>
        let baseColor: Color?
    }

    struct Chunk: Identifiable {
        let id: Int
        var text: AttributedString
        let runs: [TranscriptSegment.ID: SegmentRun]
    }

    /// Holds the signature of the chunks currently on screen. A build that never lands must not claim one.
    struct BuildGate {
        private(set) var appliedSignature: Int?

        func needsRebuild(for signature: Int) -> Bool {
            signature != appliedSignature
        }

        mutating func applied(_ signature: Int) {
            appliedSignature = signature
        }

        mutating func reset() {
            appliedSignature = nil
        }
    }

    nonisolated static let softSegmentCap = 40
    nonisolated static let hardSegmentCap = 48

    let scrollProxy: ScrollViewProxy

    @Environment(AppModel.self) private var model
    @State private var chunks: [Chunk] = []
    @State private var chunkIndexBySegment: [TranscriptSegment.ID: Int] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?
    @State private var gate = BuildGate()
    @State private var buildTask: Task<Void, Never>?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DS.Spacing.regular) {
            ForEach(chunks) { chunk in
                Text(chunk.text)
                    .font(model.transcriptCompact ? DS.Font.transcriptCompact : DS.Font.transcript)
                    .lineSpacing(model.transcriptCompact ? 3 : 5)
                    .textSelection(.enabled)
                    // Definite height; without it the inspector's constraint pass re-typesets the chunk Text in a loop (main-thread freeze on long audio).
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(chunk.id)
            }
        }
        .tint(.primary)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "parola-seek", let id = url.host.flatMap(Int.init) else { return .systemAction }
            model.seekToSegment(id: id)
            return .handled
        })
        .onAppear { rebuildChunks() }
        .onChange(of: model.transcriptVersion) { _, _ in rebuildChunks() }
        .onChange(of: model.favoritesOnly) { _, _ in rebuildChunks() }
        .onChange(of: model.favoriteSegmentIDs) { _, _ in rebuildChunks() }
        .onChange(of: model.currentSegmentID) { _, _ in
            applyHighlight()
            followCurrentSegment()
        }
        .task(id: model.pendingRevealSegmentID) { await revealPendingSegment() }
    }

    /// A search result writes its segment before this view is built, so the jump is read here rather
    /// than watched on `currentSegmentID`; the chunk holding it exists only once the build lands.
    private func revealPendingSegment() async {
        guard let id = model.pendingRevealSegmentID else { return }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(16))
            if chunkIndexBySegment[id] != nil { break }
        }
        guard let chunkID = chunkIndexBySegment[id] else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo(chunkID, anchor: .center)
        }
    }

    static let synchronousBuildCap = 200

    private func rebuildChunks() {
        guard let transcript = model.transcript else {
            buildTask?.cancel()
            gate.reset()
            chunks = []
            chunkIndexBySegment = [:]
            highlightedSegmentID = nil
            return
        }
        let useSpeakerColor = model.transcriptSpeakers.count >= 2
        let favoritesOnly = model.favoritesOnly
        let favorites = model.favoriteSegmentIDs
        let segments = favoritesOnly ? transcript.segments.filter { favorites.contains($0.id) } : transcript.segments
        // transcriptVersion also bumps for mutations that can't change the rendered text
        // (duration backfill, playback bookkeeping); skip the expensive rebuild for those.
        let signature = Self.contentSignature(
            segments: segments, useSpeakerColor: useSpeakerColor, favoritesOnly: favoritesOnly, favorites: favorites
        )
        guard gate.needsRebuild(for: signature) else { return }
        buildTask?.cancel()
        // DS's resolved palette is main-actor storage; read it here so the detached build never touches it.
        let primaryText = DS.Color.primaryText
        let accent = DS.Color.accent
        if segments.count <= Self.synchronousBuildCap {
            apply(
                Self.build(segments: segments, useSpeakerColor: useSpeakerColor, primaryText: primaryText, favoriteColor: accent, favorites: favorites),
                signature: signature
            )
        } else {
            buildTask = Task {
                await Self.buildOffMain(
                    segments: segments,
                    useSpeakerColor: useSpeakerColor,
                    primaryText: primaryText,
                    favoriteColor: accent,
                    favorites: favorites,
                    signature: signature,
                    apply: apply
                )
            }
        }
    }

    /// The gate records the signature only once the chunks land, so a build the next pass cancels leaves work to do.
    static func buildOffMain(
        segments: [TranscriptSegment],
        useSpeakerColor: Bool,
        primaryText: Color,
        favoriteColor: Color = .accentColor,
        favorites: Set<Int> = [],
        signature: Int,
        apply: ([Chunk], Int) -> Void
    ) async {
        let built = await Task.detached(priority: .userInitiated) {
            build(segments: segments, useSpeakerColor: useSpeakerColor, primaryText: primaryText, favoriteColor: favoriteColor, favorites: favorites)
        }.value
        guard !Task.isCancelled else { return }
        apply(built, signature)
    }

    private func apply(_ built: [Chunk], signature: Int) {
        chunks = built
        chunkIndexBySegment = Self.chunkIndexBySegment(for: built)
        highlightedSegmentID = nil
        gate.applied(signature)
        applyHighlight()
    }

    nonisolated static func contentSignature(
        segments: [TranscriptSegment], useSpeakerColor: Bool, favoritesOnly: Bool = false, favorites: Set<Int> = []
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(useSpeakerColor)
        hasher.combine(favoritesOnly)
        for seg in segments {
            hasher.combine(seg.id)
            hasher.combine(seg.text)
            hasher.combine(seg.speaker)
            // Timings are part of the render: a gap between two segments decides where a paragraph breaks.
            hasher.combine(seg.start)
            hasher.combine(seg.end)
            hasher.combine(favorites.contains(seg.id))
        }
        return hasher.finalize()
    }

    private func applyHighlight() {
        let nextID = model.currentSegmentID
        guard nextID != highlightedSegmentID else { return }
        Self.moveHighlight(
            in: &chunks,
            chunkIndexBySegment: chunkIndexBySegment,
            from: highlightedSegmentID,
            to: nextID,
            highlightColor: DS.Color.highlight
        )
        highlightedSegmentID = nextID
    }

    private func followCurrentSegment() {
        guard let id = model.currentSegmentID,
              model.player?.timeControlStatus == .playing || model.findIsOpen,
              let chunkID = chunkIndexBySegment[id] else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo(chunkID, anchor: .center)
        }
    }

    nonisolated static func build(
        segments: [TranscriptSegment],
        useSpeakerColor: Bool,
        primaryText: Color,
        favoriteColor: Color = .accentColor,
        favorites: Set<Int> = [],
        softCap: Int = ContinuousChunks.softSegmentCap,
        hardCap: Int = ContinuousChunks.hardSegmentCap,
        paragraphPause: TimeInterval = TranscriptDerive.paragraphPauseSeconds
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var text = AttributedString()
        var runs: [TranscriptSegment.ID: SegmentRun] = [:]
        var offset = 0
        var segmentCount = 0
        var lastEndedSentence = false
        var shownSpeaker: String?
        var lastEnd: Double?

        func closeChunk() {
            guard !text.characters.isEmpty else { return }
            chunks.append(Chunk(id: chunks.count, text: text, runs: runs))
            text = AttributedString()
            runs = [:]
            offset = 0
            segmentCount = 0
        }

        for seg in segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let pauseBreak = TranscriptParagraphs.breaksParagraph(after: lastEnd, start: seg.start, pause: paragraphPause)
            lastEnd = seg.end
            let speakerTint: Color? = useSpeakerColor ? seg.speaker.map(DS.speakerColor(for:)) : nil
            if let label = useSpeakerColor ? SegmentCard.speakerLabel(for: seg.speaker) : nil,
               label != shownSpeaker {
                closeChunk()
                var heading = AttributedString(label + "\n")
                heading.foregroundColor = speakerTint
                heading.font = DS.Font.bodyStrong
                offset += heading.characters.count
                text.append(heading)
                shownSpeaker = label
            } else if segmentCount >= hardCap || (segmentCount >= softCap && (lastEndedSentence || pauseBreak)) {
                closeChunk()
            } else if pauseBreak, !text.characters.isEmpty {
                // A blank line, not padding between views: the break has to land in the copied text too.
                let separator = AttributedString("\n\n")
                offset += separator.characters.count
                text.append(separator)
            }
            let startsLine = text.characters.isEmpty || text.characters.last == "\n"
            let isFavorite = favorites.contains(seg.id)
            if isFavorite {
                var star = AttributedString(startsLine ? "★ " : " ★ ")
                star.foregroundColor = favoriteColor
                offset += star.characters.count
                text.append(star)
            }
            var piece = AttributedString(startsLine || isFavorite ? body : " " + body)
            piece.foregroundColor = primaryText
            piece.link = URL(string: "parola-seek://\(seg.id)")
            piece.underlineStyle = nil
            let length = piece.characters.count
            runs[seg.id] = SegmentRun(offsets: offset..<offset + length, baseColor: primaryText)
            offset += length
            text.append(piece)
            segmentCount += 1
            lastEndedSentence = endsSentence(body)
        }
        closeChunk()
        return chunks
    }

    nonisolated static func chunkIndexBySegment(for chunks: [Chunk]) -> [TranscriptSegment.ID: Int] {
        var index: [TranscriptSegment.ID: Int] = [:]
        for chunk in chunks {
            for id in chunk.runs.keys { index[id] = chunk.id }
        }
        return index
    }

    static func moveHighlight(
        in chunks: inout [Chunk],
        chunkIndexBySegment: [TranscriptSegment.ID: Int],
        from previousID: TranscriptSegment.ID?,
        to nextID: TranscriptSegment.ID?,
        highlightColor: Color
    ) {
        if let previousID, let i = chunkIndexBySegment[previousID], chunks.indices.contains(i),
           let run = chunks[i].runs[previousID] {
            recolor(&chunks[i].text, offsets: run.offsets, color: run.baseColor)
        }
        if let nextID, let i = chunkIndexBySegment[nextID], chunks.indices.contains(i),
           let run = chunks[i].runs[nextID] {
            recolor(&chunks[i].text, offsets: run.offsets, color: highlightColor)
        }
    }

    private static func recolor(_ text: inout AttributedString, offsets: Range<Int>, color: Color?) {
        let chars = text.characters
        guard
            let lo = chars.index(chars.startIndex, offsetBy: offsets.lowerBound, limitedBy: chars.endIndex),
            let hi = chars.index(chars.startIndex, offsetBy: offsets.upperBound, limitedBy: chars.endIndex)
        else { return }
        text[lo..<hi].foregroundColor = color
    }

    nonisolated private static func endsSentence(_ body: String) -> Bool {
        guard let terminal = body.last(where: { !"\"')]»”’".contains($0) }) else { return false }
        return ".!?…。！？".contains(terminal)
    }
}
