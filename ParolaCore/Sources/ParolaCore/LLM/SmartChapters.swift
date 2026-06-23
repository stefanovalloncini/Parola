import Foundation

public enum SmartChapters {
    public static func parseResponse(_ text: String, maxSeconds: Double? = nil) -> [Chapter] {
        var out: [Chapter] = []
        var lastStart: Double = -1
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            guard let chapter = parseLine(String(raw)) else { continue }
            if chapter.start <= lastStart { continue }
            if let cap = maxSeconds, chapter.start > cap { continue }
            out.append(chapter)
            lastStart = chapter.start
        }
        return out
    }

    public static func generate(
        for transcript: Transcript,
        model: any LanguageModel
    ) async throws -> [Chapter] {
        let body = TranscriptPromptContext.timestampedLines(for: transcript)
        let envelope = """
        Read the transcript below and propose between 4 and 10 chapter markers that capture the major topic shifts. Output only the markers, one per line, in the form 'MM:SS Title' (or 'HH:MM:SS Title' for content over an hour). The first marker MUST start at 00:00. Titles are 3 to 7 plain words — no bullets, no quotes, no commentary.

        Transcript:
        \(body)
        """
        let response = try await model.respond(to: envelope)
        let cap = transcript.segments.map(\.end).max()
        return parseResponse(response, maxSeconds: cap)
    }

    private static let timestampWrappers = CharacterSet(charactersIn: "*_[]()`")

    private static func parseLine(_ raw: String) -> Chapter? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let rest = stripLeadingMarkers(trimmed)
        guard let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let timeToken = String(rest[..<space]).trimmingCharacters(in: timestampWrappers)
        guard let seconds = Format.parseClockTimestamp(timeToken) else { return nil }
        return Chapter.cleaned(title: String(rest[rest.index(after: space)...]), start: seconds)
    }

    static func stripLeadingMarkers(_ line: String) -> Substring {
        // Loop so stacked decoration ("1. - 00:00 Title", "- 2) 02:15 Title") fully unwinds; a
        // single drop-markers-then-spaces pass can't return to strip a marker that follows a space.
        var body = line[...]
        while true {
            let next = (stripOrderedMarker(body) ?? body)
                .drop(while: { "-*•_#".contains($0) })
                .drop(while: { $0 == " " || $0 == "\t" })
            if next.startIndex == body.startIndex { return next }
            body = next
        }
    }

    private static func stripOrderedMarker(_ line: Substring) -> Substring? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isASCII, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex,
              line[idx] == "." || line[idx] == ")" else { return nil }
        let afterDelimiter = line.index(after: idx)
        // A digit run plus "." or ")" is a list marker only when a space or line end follows, so "3.5 mg" stays prose.
        guard afterDelimiter == line.endIndex || line[afterDelimiter].isWhitespace else { return nil }
        return line[afterDelimiter...]
    }
}
