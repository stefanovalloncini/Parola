import Foundation

/// The single point where a finished transcript is tidied before anything downstream sees it:
/// the CLI, the MCP server, the exporters and both apps all read what comes out of here.
public enum TranscriptCleanup {
    public static func apply(to transcript: Transcript) -> Transcript {
        var out = transcript
        out.segments = out.segments
            .droppingBlankText()
            .chronologicallyOrdered()
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
