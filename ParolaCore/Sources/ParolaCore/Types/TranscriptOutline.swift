import Foundation

public enum TranscriptOutline {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let start: Double
        public let title: String
        public let speaker: String?

        public init(id: String, start: Double, title: String, speaker: String? = nil) {
            self.id = id
            self.start = start
            self.title = title
            self.speaker = speaker
        }
    }

    public static func entries(
        for transcript: Transcript,
        chapters: [Chapter],
        gapSeconds: Double = 120
    ) -> [Entry] {
        if !chapters.isEmpty {
            return chapters.map { Entry(id: $0.id, start: $0.start, title: $0.title, speaker: nil) }
        }
        return derive(segments: transcript.segments, gapSeconds: gapSeconds)
    }

    private static func derive(segments: [TranscriptSegment], gapSeconds: Double) -> [Entry] {
        var entries: [Entry] = []
        var lastSpeaker: String?
        var lastStart: Double = -.infinity
        for segment in segments {
            let speakerChanged = segment.speaker != nil && segment.speaker != lastSpeaker
            let gapElapsed = segment.start - lastStart >= gapSeconds
            if entries.isEmpty || speakerChanged || gapElapsed {
                entries.append(Entry(
                    id: "seg-\(segment.id)",
                    start: segment.start,
                    title: headingTitle(from: segment.text),
                    speaker: segment.speaker
                ))
                lastSpeaker = segment.speaker
                lastStart = segment.start
            }
        }
        return entries
    }

    private static func headingTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Section" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).prefix(6)
        return words.joined(separator: " ")
    }
}
