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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    if model.transcript != nil {
                        let speakers = model.transcriptSpeakers
                        if speakers.count >= 2 {
                            SpeakerFilterRow(speakers: speakers, selection: speakerFilterBinding)
                                .padding(.bottom, DS.Spacing.tight)
                        }
                        ForEach(derived.visible) { seg in
                            SegmentCard(
                                segment: seg,
                                hoveredSpeaker: $hoveredSpeaker,
                                confidenceBucket: derived.confidenceByID[seg.id],
                                qcIssues: qcByID[seg.id] ?? []
                            )
                            .id(seg.id)
                            .opacity(opacity(for: seg))
                            if let gap = derived.pauseByPrev[seg.id] {
                                LongPauseDivider(seconds: gap)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: model.currentSegmentID) { _, id in
                guard let id, model.player?.timeControlStatus == .playing || model.findIsOpen else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: speakerFilter) { _, newValue in
                if newValue != nil, model.findIsOpen { model.toggleFind() }
            }
            .onChange(of: model.findIsOpen) { _, isOpen in
                if isOpen { speakerFilterBinding.wrappedValue = nil }
            }
            .onChange(of: model.transcriptSpeakers) { _, speakers in
                if let current = speakerFilter, !speakers.contains(current) {
                    speakerFilterBinding.wrappedValue = nil
                }
            }
            .task(id: model.pendingRevealSegmentID) { await revealPendingSegment(proxy) }
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
            speakerFilter: speakerFilter
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

    /// A search result writes its segment before this view is built, so the jump is read here rather
    /// than watched on `currentSegmentID`; the row it names exists only once the derive lands, which
    /// is a detached hop for a long transcript.
    private func revealPendingSegment(_ proxy: ScrollViewProxy) async {
        guard let id = model.pendingRevealSegmentID else { return }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(16))
            if derived.visible.contains(where: { $0.id == id }) { break }
        }
        guard derived.visible.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func recomputeDerived(for key: DerivedKey) {
        deriveTask?.cancel()
        guard let segments = model.transcript?.segments else {
            derived = Derived()
            return
        }
        let speakerFilter = key.speakerFilter
        guard segments.count > TranscriptDerive.synchronousCap else {
            derived = Self.derive(segments: segments, speakerFilter: speakerFilter)
            return
        }
        deriveTask = Task {
            let computed = await Task.detached(priority: .userInitiated) {
                Self.derive(segments: segments, speakerFilter: speakerFilter)
            }.value
            guard !Task.isCancelled else { return }
            derived = computed
        }
    }

    private func recomputeQC(for key: QCKey) {
        qcTask?.cancel()
        guard key.enabled, let segments = model.transcript?.segments else {
            qcByID = [:]
            return
        }
        let captionLength = key.captionLength
        guard segments.count > TranscriptDerive.synchronousCap else {
            qcByID = Self.subtitleQCIssues(segments: segments, captionLength: captionLength)
            return
        }
        // Segment ids repeat across entries, so a kept-around map would badge the new entry's cards until the rebuild lands.
        qcByID = [:]
        qcTask = Task {
            let computed = await Task.detached(priority: .userInitiated) {
                Self.subtitleQCIssues(segments: segments, captionLength: captionLength)
            }.value
            guard !Task.isCancelled else { return }
            qcByID = computed
        }
    }

    nonisolated static func derive(segments: [TranscriptSegment], speakerFilter: String?) -> Derived {
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
            visible: visibleSegments(from: segments, speakerFilter: speakerFilter)
        )
    }

    nonisolated static func subtitleQCIssues(
        segments: [TranscriptSegment],
        captionLength: CaptionLength
    ) -> [Int: [SubtitleQC.Issue]] {
        var issuesByID: [Int: [SubtitleQC.Issue]] = [:]
        for segment in segments {
            let issues = SubtitleQC.issues(for: segment, captionLength: captionLength)
            if !issues.isEmpty { issuesByID[segment.id] = issues }
        }
        return issuesByID
    }

    nonisolated static func visibleSegments(from segments: [TranscriptSegment], speakerFilter: String?) -> [TranscriptSegment] {
        segments.filter { segment in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let speakerFilter else { return true }
            return segment.speaker == speakerFilter
        }
    }

    private func opacity(for segment: TranscriptSegment) -> Double {
        guard let hoveredSpeaker else { return 1.0 }
        return segment.speaker == hoveredSpeaker ? 1.0 : 0.35
    }
}
