import SwiftUI
import ParolaCore

struct SegmentsScroll: View {
    struct Derived {
        var pauseByPrev: [Int: Double] = [:]
        var confidenceByID: [Int: SegmentConfidence.Bucket] = [:]
        var visible: [TranscriptSegment] = []
    }

    private struct DerivedKey: Equatable {
        let transcriptVersion: Int
        let entryID: LibraryEntry.ID?
        let speakerFilter: String?
        let favoritesOnly: Bool
        let favorites: Set<Int>
    }

    private struct QCKey: Equatable {
        let transcriptVersion: Int
        let entryID: LibraryEntry.ID?
        let enabled: Bool
        let captionLength: CaptionLength
    }

    @Environment(AppModel.self) private var model
    @State private var hoveredSpeaker: String?
    @State private var derived = Derived()
    @State private var qcByID: [Int: [SubtitleQC.Issue]] = [:]
    @State private var deriveTask: Task<Void, Never>?
    @State private var qcTask: Task<Void, Never>?
    @State private var qcEntryID: LibraryEntry.ID?

    private var speakerFilterBinding: Binding<String?> {
        Binding(
            get: {
                guard let entryID = model.selectedEntryID else { return nil }
                return model.entrySpeakerFilters[entryID]
            },
            set: { newValue in
                guard let entryID = model.selectedEntryID else { return }
                if let newValue {
                    model.entrySpeakerFilters[entryID] = newValue
                } else {
                    model.entrySpeakerFilters.removeValue(forKey: entryID)
                }
            }
        )
    }

    private var speakerFilter: String? {
        speakerFilterBinding.wrappedValue
    }

    var body: some View {
        ScrollViewReader { proxy in
            let _ = BodyProbe.hit("SegmentsScroll", model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    if model.transcript != nil {
                        TranscriptTitleHeading()
                        let speakers = model.transcriptSpeakers
                        let translations = model.transcript?.translation?.segments ?? [:]
                        if speakers.count >= 2 {
                            SpeakerFilterRow(speakers: speakers, selection: speakerFilterBinding)
                                .padding(.bottom, DS.Spacing.tight)
                        }
                        ForEach(derived.visible) { seg in
                            CurrentSegmentCard(
                                segment: seg,
                                hoveredSpeaker: $hoveredSpeaker,
                                confidenceBucket: derived.confidenceByID[seg.id],
                                qcIssues: qcByID[seg.id] ?? [],
                                translation: translations[seg.id],
                                translationSideBySide: model.translationSideBySide
                            )
                            .id(seg.id)
                            .opacity(opacity(for: seg))
                            if let gap = derived.pauseByPrev[seg.id] {
                                LongPauseDivider(seconds: gap)
                            }
                        }
                    }
                }
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background {
                PlaybackFollower(proxy: proxy, speakerFilter: speakerFilterBinding) { id in
                    derived.visible.contains { $0.id == id }
                }
            }
            .onChange(of: speakerFilter) { _, newValue in
                if newValue != nil, model.findIsOpen { model.toggleFind() }
            }
            .onChange(of: model.transcriptSpeakers) { _, speakers in
                if let current = speakerFilter, !speakers.contains(current) {
                    speakerFilterBinding.wrappedValue = nil
                }
            }
            // Synchronous so a short transcript commits in the same pass the key changed in, not a frame later.
            .onChange(of: derivedKey, initial: true) { _, key in recomputeDerived(for: key) }
            .onChange(of: qcKey, initial: true) { _, key in recomputeQC(for: key) }
            .onDisappear {
                deriveTask?.cancel()
                qcTask?.cancel()
            }
        }
    }

    private var derivedKey: DerivedKey {
        DerivedKey(
            transcriptVersion: model.transcriptVersion,
            entryID: model.selectedEntryID,
            speakerFilter: speakerFilter,
            favoritesOnly: model.favoritesOnly,
            // With the filter off the set cannot change the result, and carrying it would re-derive
            // the whole transcript on every star click.
            favorites: model.favoritesOnly ? model.selectedEntryFavorites : []
        )
    }

    private var qcKey: QCKey {
        QCKey(
            transcriptVersion: model.transcriptVersion,
            entryID: model.selectedEntryID,
            enabled: model.showSubtitleQC,
            captionLength: model.subtitleCaptionLength
        )
    }

    private func recomputeDerived(for key: DerivedKey) {
        deriveTask?.cancel()
        guard let segments = model.transcript?.segments else {
            derived = Derived()
            return
        }
        let speakerFilter = key.speakerFilter
        let favorites = key.favorites
        let favoritesOnly = key.favoritesOnly
        guard segments.count > TranscriptDerive.synchronousCap else {
            derived = Self.derive(segments: segments, speakerFilter: speakerFilter, favorites: favorites, favoritesOnly: favoritesOnly)
            return
        }
        deriveTask = Task {
            let computed = await Task.detached(priority: .userInitiated) {
                Self.derive(segments: segments, speakerFilter: speakerFilter, favorites: favorites, favoritesOnly: favoritesOnly)
            }.value
            guard !Task.isCancelled else { return }
            derived = computed
        }
    }

    private func recomputeQC(for key: QCKey) {
        qcTask?.cancel()
        guard key.enabled, let segments = model.transcript?.segments else {
            qcByID = [:]
            qcEntryID = nil
            return
        }
        let captionLength = key.captionLength
        let language = model.transcript?.language
        // Segment ids repeat across entries, so a kept-around map would badge the new entry's cards until the rebuild lands.
        if qcEntryID != key.entryID { qcByID = [:] }
        qcEntryID = key.entryID
        qcTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                Self.subtitleQCIssues(segments: segments, captionLength: captionLength, language: language)
            }
            let computed = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            qcByID = computed
        }
    }

    nonisolated static func derive(
        segments: [TranscriptSegment], speakerFilter: String?, favorites: Set<Int>, favoritesOnly: Bool
    ) -> Derived {
        var pauseByPrev: [Int: Double] = [:]
        for pause in SegmentPauses.detect(segments: segments, thresholdSeconds: 3.0) {
            pauseByPrev[pause.afterSegmentID] = pause.durationSeconds
        }
        var confidenceByID: [Int: SegmentConfidence.Bucket] = [:]
        for segment in segments {
            if let value = SegmentConfidence.average(for: segment) {
                confidenceByID[segment.id] = SegmentConfidence.bucket(for: value)
            }
        }
        return Derived(
            pauseByPrev: pauseByPrev,
            confidenceByID: confidenceByID,
            visible: visibleSegments(from: segments, speakerFilter: speakerFilter, favorites: favorites, favoritesOnly: favoritesOnly)
        )
    }

    nonisolated static func subtitleQCIssues(
        segments: [TranscriptSegment],
        captionLength: CaptionLength,
        language: String? = nil
    ) -> [Int: [SubtitleQC.Issue]] {
        SubtitleQC.issues(forSegments: segments, captionLength: captionLength, language: language)
    }

    nonisolated static func visibleSegments(
        from segments: [TranscriptSegment], speakerFilter: String?, favorites: Set<Int>, favoritesOnly: Bool
    ) -> [TranscriptSegment] {
        segments.filter { segment in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if let speakerFilter, segment.speaker != speakerFilter { return false }
            guard !favoritesOnly || favorites.contains(segment.id) else { return false }
            return true
        }
    }

    private func opacity(for segment: TranscriptSegment) -> Double {
        guard let hoveredSpeaker else { return 1.0 }
        return segment.speaker == hoveredSpeaker ? 1.0 : 0.35
    }
}

/// Reads the playhead so the scroll's own body doesn't; only the two cards whose current flag flips re-run.
private struct CurrentSegmentCard: View {
    let segment: TranscriptSegment
    let hoveredSpeaker: Binding<String?>
    let confidenceBucket: SegmentConfidence.Bucket?
    let qcIssues: [SubtitleQC.Issue]
    let translation: String?
    let translationSideBySide: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        SegmentCard(
            segment: segment,
            isCurrent: model.currentSegmentID == segment.id,
            hoveredSpeaker: hoveredSpeaker,
            confidenceBucket: confidenceBucket,
            qcIssues: qcIssues,
            translation: translation,
            translationSideBySide: translationSideBySide
        )
        .equatable()
    }
}

/// Scrolls to the playing segment and to a search hit; a zero-size view so these reads leave the scroll's body alone.
private struct PlaybackFollower: View {
    let proxy: ScrollViewProxy
    let speakerFilter: Binding<String?>
    let isShown: (TranscriptSegment.ID) -> Bool

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.currentSegmentID) { _, id in
                guard let id, model.player?.timeControlStatus == .playing || model.findIsOpen else { return }
                withAnimation(DS.Motion.follow(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: model.findIsOpen) { _, isOpen in
                if isOpen { speakerFilter.wrappedValue = nil }
            }
            .task(id: model.pendingRevealSegmentID) { await revealPendingSegment() }
    }

    /// A search result writes its segment before this view is built, so the jump is read here rather
    /// than watched on `currentSegmentID`; the row it names exists only once the derive lands, which
    /// is a detached hop for a long transcript.
    private func revealPendingSegment() async {
        guard let id = model.pendingRevealSegmentID else { return }
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            try? await Task.sleep(for: .milliseconds(16))
        } while !(isShown(id)) && !Task.isCancelled && ContinuousClock.now < deadline
        guard isShown(id) else { return }
        withAnimation(DS.Motion.follow(reduceMotion: reduceMotion)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
