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
        var body = ""
        for segment in transcript.segments {
            let ts = Timecode.format(segment.start)
            body += "\(ts)  \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        let envelope = """
        Read the transcript below and propose between 4 and 10 chapter markers that capture the major topic shifts. Output only the markers, one per line, in the form 'MM:SS Title' (or 'HH:MM:SS Title' for content over an hour). The first marker MUST start at 00:00. Titles are 3 to 7 plain words — no bullets, no quotes, no commentary.

        Transcript:
        \(body)
        """
        let response = try await model.respond(to: envelope)
        let cap = transcript.segments.last.map { $0.start + $0.duration } ?? nil
        return parseResponse(response, maxSeconds: cap)
    }

    private static func parseLine(_ raw: String) -> Chapter? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var rest = trimmed[...]
        if let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let timeToken = String(rest[..<space])
            guard let seconds = Timecode.parse(timeToken) else { return nil }
            rest = rest[rest.index(after: space)...]
            let title = cleanTitle(String(rest))
            guard !title.isEmpty else { return nil }
            return Chapter(title: title, start: seconds)
        }
        return nil
    }

    private static func cleanTitle(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while let first = result.first, "-—–•\"'".contains(first) {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while let last = result.last, "\"'".contains(last) {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
