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
        let rawText: String
    }

    struct Chunk: Identifiable {
        let id: Int
        var text: AttributedString
        var translation: AttributedString?
        let runs: [TranscriptSegment.ID: SegmentRun]
        /// The speaker this run belongs to, so the chunk can offer to assign it.
        var speaker: String?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chunks: [Chunk] = []
    @State private var chunkIndexBySegment: [TranscriptSegment.ID: Int] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?
    @State private var gate = BuildGate()
    @State private var buildTask: Task<Void, Never>?
    @State private var assigningChunkID: Chunk.ID?
    @State private var renamingSpeaker: String?
    @State private var draftSpeakerName: String = ""

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DS.Spacing.regular) {
            ForEach(chunks) { chunk in
                chunkRow(chunk)
                    .id(chunk.id)
            }
        }
        .tint(.primary)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "parola-assign", let chunk = url.host.flatMap(Int.init) {
                assigningChunkID = chunk
                return .handled
            }
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
        .alert("Rename speaker", isPresented: isRenamingSpeaker, presenting: renamingSpeaker) { current in
            TextField("Name", text: $draftSpeakerName)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Rename") {
                let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                renamingSpeaker = nil
                model.renameSpeakerLabel(current, to: trimmed)
            }
        }
    }

    private var isRenamingSpeaker: Binding<Bool> {
        Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })
    }

    private func assigningBinding(for chunk: Chunk) -> Binding<Bool> {
        Binding(
            get: { assigningChunkID == chunk.id },
            set: { assigningChunkID = $0 ? chunk.id : nil }
        )
    }

    @ViewBuilder
    private func chunkRow(_ chunk: Chunk) -> some View {
        let text = model.matches.isEmpty
            ? chunk.text
            : Self.searched(chunk, matches: model.match(in:), currentMatchID: model.currentMatch?.id)
        Group {
            if let translation = chunk.translation, model.translationSideBySide {
                HStack(alignment: .top, spacing: DS.Spacing.regular) {
                    chunkText(text)
                    chunkText(translation)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    chunkText(text)
                    if let translation = chunk.translation {
                        chunkText(translation)
                    }
                }
            }
        }
        .modifier(ChunkSpeakerAssignment(
            speaker: chunk.speaker,
            isPresented: assigningBinding(for: chunk),
            onRenameLabel: { label in
                draftSpeakerName = label
                renamingSpeaker = label
            }
        ))
    }

    private func chunkText(_ text: AttributedString) -> some View {
        Text(text)
            .font(model.transcriptCompact ? DS.Font.transcriptCompact : DS.Font.transcript)
            .lineSpacing(model.transcriptCompact ? DS.Spacing.transcriptLeadingCompact : DS.Spacing.transcriptLeading)
            .textSelection(.enabled)
            // Definite height; without it the inspector's constraint pass re-typesets the chunk Text in a loop (main-thread freeze on long audio).
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        withAnimation(DS.Motion.follow(reduceMotion: reduceMotion)) {
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
        let speakerColorIndices = useSpeakerColor ? model.speakerColorIndices : [:]
        let favoritesOnly = model.favoritesOnly
        let favorites = model.favoriteSegmentIDs
        let segments = favoritesOnly ? transcript.segments.filter { favorites.contains($0.id) } : transcript.segments
        let translations = transcript.translation?.segments ?? [:]
        // transcriptVersion also bumps for mutations that can't change the rendered text
        // (duration backfill, playback bookkeeping); skip the expensive rebuild for those.
        let signature = Self.contentSignature(
            segments: segments, useSpeakerColor: useSpeakerColor, favoritesOnly: favoritesOnly,
            favorites: favorites, translations: translations, speakerColorIndices: speakerColorIndices
        )
        guard gate.needsRebuild(for: signature) else { return }
        buildTask?.cancel()
        // DS's resolved palette is main-actor storage; read it here so the detached build never touches it.
        let primaryText = DS.Color.primaryText
        let accent = DS.Color.accent
        let secondaryText = DS.Color.secondaryText
        if segments.count <= Self.synchronousBuildCap {
            apply(
                Self.build(
                    segments: segments, useSpeakerColor: useSpeakerColor,
                    speakerColorIndices: speakerColorIndices, primaryText: primaryText,
                    favoriteColor: accent, favorites: favorites, translations: translations,
                    translationColor: secondaryText
                ),
                signature: signature
            )
        } else {
            buildTask = Task {
                await Self.buildOffMain(
                    segments: segments,
                    useSpeakerColor: useSpeakerColor,
                    speakerColorIndices: speakerColorIndices,
                    primaryText: primaryText,
                    favoriteColor: accent,
                    favorites: favorites,
                    translations: translations,
                    translationColor: secondaryText,
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
        speakerColorIndices: [String: Int],
        primaryText: Color,
        favoriteColor: Color,
        favorites: Set<Int>,
        translations: [Int: String],
        translationColor: Color,
        signature: Int,
        apply: ([Chunk], Int) -> Void
    ) async {
        let built = await Task.detached(priority: .userInitiated) {
            build(
                segments: segments, useSpeakerColor: useSpeakerColor,
                speakerColorIndices: speakerColorIndices, primaryText: primaryText,
                favoriteColor: favoriteColor, favorites: favorites, translations: translations,
                translationColor: translationColor
            )
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
        segments: [TranscriptSegment], useSpeakerColor: Bool, favoritesOnly: Bool, favorites: Set<Int>,
        translations: [Int: String], speakerColorIndices: [String: Int]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(useSpeakerColor)
        hasher.combine(favoritesOnly)
        for (label, index) in speakerColorIndices.sorted(by: { $0.key < $1.key }) {
            hasher.combine(label)
            hasher.combine(index)
        }
        for seg in segments {
            hasher.combine(seg.id)
            hasher.combine(seg.text)
            hasher.combine(seg.speaker)
            // Timings are part of the render: a gap between two segments decides where a paragraph breaks.
            hasher.combine(seg.start)
            hasher.combine(seg.end)
            hasher.combine(favorites.contains(seg.id))
            hasher.combine(translations[seg.id])
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
        withAnimation(DS.Motion.follow(reduceMotion: reduceMotion)) {
            scrollProxy.scrollTo(chunkID, anchor: .center)
        }
    }

    nonisolated static func build(
        segments: [TranscriptSegment],
        useSpeakerColor: Bool,
        speakerColorIndices: [String: Int],
        primaryText: Color,
        favoriteColor: Color,
        favorites: Set<Int>,
        translations: [Int: String],
        translationColor: Color,
        softCap: Int = ContinuousChunks.softSegmentCap,
        hardCap: Int = ContinuousChunks.hardSegmentCap,
        paragraphPause: TimeInterval = TranscriptDerive.paragraphPauseSeconds
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var text = AttributedString()
        var translated = AttributedString()
        // Headings and paragraph breaks wait here until a translated line needs them, so a chunk
        // that starts with untranslated segments still lines its two columns up.
        var translatedPrefix = AttributedString()
        var translatedSegments = 0
        var runs: [TranscriptSegment.ID: SegmentRun] = [:]
        var offset = 0
        var segmentCount = 0
        var lastEndedSentence = false
        var shownSpeaker: String?
        // The raw label, not the flattened one the heading shows: the manifest's speaker map is
        // keyed by what the segment carries, and the assign popover has to look it up under that.
        var chunkSpeaker: String?
        var lastEnd: Double?

        func closeChunk() {
            guard !text.characters.isEmpty else { return }
            chunks.append(Chunk(
                id: chunks.count,
                text: text,
                translation: translatedSegments == 0 ? nil : translated,
                runs: runs,
                speaker: chunkSpeaker
            ))
            text = AttributedString()
            translated = AttributedString()
            translatedPrefix = AttributedString()
            translatedSegments = 0
            runs = [:]
            offset = 0
            segmentCount = 0
        }

        for seg in segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let pauseBreak = TranscriptParagraphs.breaksParagraph(after: lastEnd, start: seg.start, pause: paragraphPause)
            lastEnd = seg.end
            let speakerTint: Color? = useSpeakerColor
                ? seg.speaker.map { DS.speakerColor(for: $0, colorIndex: speakerColorIndices[$0]) }
                : nil
            if let label = useSpeakerColor ? SegmentCard.speakerLabel(for: seg.speaker) : nil,
               label != shownSpeaker {
                closeChunk()
                var heading = AttributedString(label + "\n")
                heading.foregroundColor = speakerTint
                heading.font = DS.Font.bodyStrong
                // A link, not a gesture: a selectable Text answers a right-click with the system
                // editing menu, so the heading has to carry the assign affordance itself.
                heading.link = URL(string: "parola-assign://\(chunks.count)")
                heading.underlineStyle = nil
                offset += heading.characters.count
                text.append(heading)
                translatedPrefix = heading
                shownSpeaker = label
                chunkSpeaker = seg.speaker
            } else if segmentCount >= hardCap || (segmentCount >= softCap && (lastEndedSentence || pauseBreak)) {
                closeChunk()
            } else if pauseBreak, !text.characters.isEmpty {
                // A blank line, not padding between views: the break has to land in the copied text too.
                let separator = AttributedString("\n\n")
                offset += separator.characters.count
                text.append(separator)
                if !translated.characters.isEmpty { translatedPrefix.append(separator) }
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
            runs[seg.id] = SegmentRun(offsets: offset..<offset + length, baseColor: primaryText, rawText: seg.text)
            offset += length
            text.append(piece)
            if let translation = translations[seg.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty {
                translated.append(translatedPrefix)
                translatedPrefix = AttributedString()
                let startsTranslatedLine = translated.characters.isEmpty || translated.characters.last == "\n"
                var translatedPiece = AttributedString(startsTranslatedLine ? translation : " " + translation)
                translatedPiece.foregroundColor = translationColor
                translated.append(translatedPiece)
                translatedSegments += 1
            }
            segmentCount += 1
            lastEndedSentence = endsSentence(body)
        }
        closeChunk()
        return chunks
    }

    /// Painted per row, not in the stored chunks: only the paragraphs on screen pay, and the playhead's tint survives.
    static func searched(
        _ chunk: Chunk,
        matches: (TranscriptSegment.ID) -> [TranscriptMatch],
        currentMatchID: TranscriptMatch.ID?
    ) -> AttributedString {
        var text = chunk.text
        for (segmentID, run) in chunk.runs {
            let segmentMatches = matches(segmentID)
            guard !segmentMatches.isEmpty else { continue }
            TranscriptSearchHighlight.paint(
                in: &text,
                runOffsets: run.offsets,
                rawText: run.rawText,
                matches: segmentMatches,
                currentMatchID: currentMatchID
            )
        }
        return text
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

/// A speaker run's assign affordance: the context menu that opens the popover, and the popover.
private struct ChunkSpeakerAssignment: ViewModifier {
    let speaker: String?
    @Binding var isPresented: Bool
    let onRenameLabel: (String) -> Void

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let speaker, let label = SegmentCard.speakerLabel(for: speaker) {
            content
                .contextMenu {
                    Button("Assign \(label)…") { isPresented = true }
                        .axLeaf("Chunk.MenuItem.AssignSpeaker")
                }
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    AssignSpeakerPopover(label: speaker) { onRenameLabel(speaker) }
                        .environment(model)
                }
        } else {
            content
        }
    }
}
