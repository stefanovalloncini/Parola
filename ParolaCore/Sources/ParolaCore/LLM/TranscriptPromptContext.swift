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

    /// The UTF-8 length of `timestampedLines`, line by line, so a size check never joins the whole transcript.
    static func timestampedLinesUTF8Count(for transcript: Transcript) -> Int {
        transcript.segments.reduce(0) { $0 + (timestampedLine(for: $1)?.utf8.count ?? 0) }
    }

    // Each segment must stay a single timestamped line in the prompt; a blank one renders nothing.
    static func timestampedLine(for segment: TranscriptSegment) -> String? {
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker, !speaker.isEmpty else {
            return "\(Timecode.format(segment.start))  \(body)\n"
        }
        return "\(Timecode.format(segment.start))  \(speaker): \(body)\n"
    }
}
