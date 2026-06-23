import Foundation

public enum NotesMarkdownRenderer {
    public static func render(transcript: Transcript, notes: [String: String], title: String) -> String {
        var out = "# \(title) — Notes\n\n"
        let entries = transcript.segments
            .compactMap { segment -> (segment: TranscriptSegment, note: String)? in
                guard let note = notes[String(segment.id)], !note.isEmpty else { return nil }
                return (segment, note)
            }
            .sorted { $0.segment.start < $1.segment.start }
        for entry in entries {
            let stamp = Timecode.format(entry.segment.start)
            if let speaker = Format.presentationSpeakerLabel(entry.segment.speaker) {
                out += "- **\(stamp) · \(speaker)** — \(entry.note)\n"
            } else {
                out += "- **\(stamp)** — \(entry.note)\n"
            }
        }
        return out
    }
}
