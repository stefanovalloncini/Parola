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

    static let synchronousDeriveCap = 200

    @Environment(AppModel.self) private var model
    @State private var hoveredSpeaker: String?
    @State private var derived = Derived()
    @State private var qcByID: [Int: [SubtitleQC.Issue]] = [:]

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
                                isCurrent: seg.id == model.currentSegmentID,
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
            .task(id: derivedKey) { await recomputeDerived() }
            .task(id: qcKey) { await recomputeQC() }
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

    private func recomputeDerived() async {
        guard let segments = model.transcript?.segments else {
            derived = Derived()
            return
        }
        let speakerFilter = speakerFilter
        guard segments.count > Self.synchronousDeriveCap else {
            derived = Self.derive(segments: segments, speakerFilter: speakerFilter)
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            Self.derive(segments: segments, speakerFilter: speakerFilter)
        }.value
        guard !Task.isCancelled else { return }
        derived = computed
    }

    private func recomputeQC() async {
        guard model.showSubtitleQC, let segments = model.transcript?.segments else {
            qcByID = [:]
            return
        }
        let captionLength = model.subtitleCaptionLength
        guard segments.count > Self.synchronousDeriveCap else {
            qcByID = Self.subtitleQCIssues(segments: segments, captionLength: captionLength)
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            Self.subtitleQCIssues(segments: segments, captionLength: captionLength)
        }.value
        guard !Task.isCancelled else { return }
        qcByID = computed
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
