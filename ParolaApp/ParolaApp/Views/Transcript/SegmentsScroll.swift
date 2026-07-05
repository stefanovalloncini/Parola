import SwiftUI
import ParolaCore

struct SegmentsScroll: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredSpeaker: String?
    @State private var pauseByPrev: [Int: Double] = [:]
    @State private var confidenceByID: [Int: SegmentConfidence.Bucket] = [:]
    @State private var qcByID: [Int: [SubtitleQC.Issue]] = [:]
    @State private var visibleSegmentsCache: [TranscriptSegment] = []

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
                        ForEach(visibleSegmentsCache) { seg in
                            SegmentCard(
                                segment: seg,
                                isCurrent: seg.id == model.currentSegmentID,
                                hoveredSpeaker: $hoveredSpeaker,
                                confidenceBucket: confidenceByID[seg.id],
                                qcIssues: qcByID[seg.id] ?? []
                            )
                            .id(seg.id)
                            .opacity(opacity(for: seg))
                            if let gap = pauseByPrev[seg.id] {
                                LongPauseDivider(seconds: gap)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: model.currentSegmentID) { _, id in
                guard let id, model.player?.timeControlStatus == .playing else { return }
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
            .onAppear {
                recomputeDerived()
                recomputeVisible()
            }
            .onChange(of: model.transcriptVersion) { _, _ in
                recomputeDerived()
                recomputeVisible()
            }
            .onChange(of: model.selectedEntryID) { _, _ in
                recomputeDerived()
                recomputeVisible()
            }
            .onChange(of: speakerFilter) { _, _ in recomputeVisible() }
            .onChange(of: model.showSubtitleQC) { _, _ in recomputeQC() }
            .onChange(of: model.subtitleCaptionLengthRaw) { _, _ in recomputeQC() }
        }
    }

    private func recomputeDerived() {
        recomputeQC()
        guard let segments = model.transcript?.segments else {
            pauseByPrev = [:]
            confidenceByID = [:]
            return
        }
        pauseByPrev = Dictionary(
            uniqueKeysWithValues: SegmentPauses
                .detect(segments: segments, thresholdSeconds: 3.0)
                .map { ($0.afterSegmentID, $0.durationSeconds) }
        )
        var buckets: [Int: SegmentConfidence.Bucket] = [:]
        for segment in segments {
            if let value = SegmentConfidence.average(for: segment) {
                buckets[segment.id] = SegmentConfidence.bucket(for: value)
            }
        }
        confidenceByID = buckets
    }

    private func recomputeQC() {
        guard model.showSubtitleQC, let segments = model.transcript?.segments else {
            qcByID = [:]
            return
        }
        qcByID = Self.subtitleQCIssues(segments: segments, captionLength: model.subtitleCaptionLength)
    }

    static func subtitleQCIssues(
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

    private func recomputeVisible() {
        guard let segments = model.transcript?.segments else {
            visibleSegmentsCache = []
            return
        }
        visibleSegmentsCache = Self.visibleSegments(from: segments, speakerFilter: speakerFilter)
    }

    static func visibleSegments(from segments: [TranscriptSegment], speakerFilter: String?) -> [TranscriptSegment] {
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
