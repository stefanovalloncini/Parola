import Foundation

public struct TranscriptCleanupOptions: Sendable {
    public var filtersHallucinations: Bool

    public init(filtersHallucinations: Bool = true) {
        self.filtersHallucinations = filtersHallucinations
    }
}

/// The single point where a finished transcript is tidied before anything downstream sees it:
/// the CLI, the MCP server, the exporters and both apps all read what comes out of here.
public enum TranscriptCleanup {
    public static func apply(
        to transcript: Transcript,
        options: TranscriptCleanupOptions = TranscriptCleanupOptions()
    ) -> Transcript {
        var segments = transcript.segments.droppingBlankText()
        if options.filtersHallucinations {
            segments = IgnoredSegments.applyBuiltInDefaults(to: segments)
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
