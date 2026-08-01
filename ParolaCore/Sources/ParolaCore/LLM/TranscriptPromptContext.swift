import Foundation

enum TranscriptPromptContext {
    static func timestampedLines(for transcript: Transcript) -> String {
        var out = ""
        for segment in transcript.segments {
            guard let line = timestampedLine(for: segment) else { continue }
            out += line
        }
        return out
    }

    // Each segment must stay a single timestamped line in the prompt; a blank one renders nothing.
    static func timestampedLine(for segment: TranscriptSegment) -> String? {
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "\(Timecode.format(segment.start))  \(body)\n"
    }
}
