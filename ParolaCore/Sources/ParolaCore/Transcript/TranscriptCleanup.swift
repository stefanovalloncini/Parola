import Foundation

public struct TranscriptCleanupOptions: Sendable {
    public var filtersHallucinations: Bool

    /// Whisper cuts mid-sentence; engines that already emit sentence-shaped segments leave
    /// this off so their own segmentation survives.
    public var mergesSentences: Bool

    public init(filtersHallucinations: Bool = true, mergesSentences: Bool = false) {
        self.filtersHallucinations = filtersHallucinations
        self.mergesSentences = mergesSentences
    }
}

/// The single point where a finished transcript is tidied before anything downstream sees it:
/// the CLI, the MCP server, the exporters and both apps all read what comes out of here.
public enum TranscriptCleanup {
    public static func apply(
        to transcript: Transcript,
        options: TranscriptCleanupOptions = TranscriptCleanupOptions()
    ) -> Transcript {
        apply(to: transcript, options: options, energy: nil)
    }

    /// The energy probe is what lets the pass drop a line repeated over silence; a run with no file
    /// behind it — a live stream, or a document read back from the library — passes nil and keeps
    /// every repetition.
    static func apply(
        to transcript: Transcript,
        options: TranscriptCleanupOptions,
        energy: SegmentEnergyProbe?
    ) -> Transcript {
        var segments = transcript.segments.droppingBlankText()
        if options.filtersHallucinations {
            if let energy {
                segments = SilentRepetitions.dropped(from: segments, probe: energy)
            }
            segments = IgnoredSegments.applyBuiltInDefaults(to: segments)
        }
        if options.mergesSentences {
            segments = SentenceMerger.merged(segments.chronologicallyOrdered())
        }
        var out = transcript
        out.segments = segments.chronologicallyOrdered()
        return out
    }
}

extension Array where Element == TranscriptSegment {
    /// Whisper emits silent VAD chunks as segments with real timings and no text, which show
    /// up as blank rows in JSON, CSV and the transcript list.
    func droppingBlankText() -> [TranscriptSegment] {
        filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
