import Foundation

enum TranscriptPromptContext {
    static func timestampedLines(for transcript: Transcript) -> String {
        var out = ""
        for segment in transcript.segments {
            // Each segment must stay a single timestamped line in the prompt.
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out += "\(Timecode.format(segment.start))  \(body)\n"
        }
        return out
    }
}
