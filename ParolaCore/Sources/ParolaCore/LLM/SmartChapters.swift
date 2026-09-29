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

    /// Chapter markers for the transcript. One too long for `budget` is asked about window by window,
    /// each window's markers kept to its own span and the whole merged in order.
    public static func generate(
        for transcript: Transcript,
        model: any LanguageModel,
        budget: TokenBudget
    ) async throws -> [Chapter] {
        try await markers(for: transcript, model: model, budget: budget, ask: smartChaptersAsk).chapters
    }

    struct Markers {
        let responses: [String]
        let chapters: [Chapter]
    }

    static func markers(
        for transcript: Transcript,
        model: any LanguageModel,
        budget: TokenBudget,
        ask: (_ firstMarker: String) -> String
    ) async throws -> Markers {
        let firstID = transcript.segments.first?.id
        let windows = await TranscriptWindows.split(
            transcript,
            budget: budget,
            instructions: LanguageModelFactory.defaultInstructions,
            line: TranscriptPromptContext.timestampedLine(for:),
            render: { window in
                let opensTranscript = window.segments.first?.id == firstID
                let first = opensTranscript ? "00:00" : Timecode.format(window.segments.first?.start ?? 0)
                return ask(first) + "\n\nTranscript:\n" + TranscriptPromptContext.timestampedLines(for: window)
            }
        )
        let cap = transcript.segments.map(\.end).max()
        guard windows.count > 1 else {
            let response = try await model.respond(to: windows[0].text)
            return Markers(responses: [response], chapters: parseResponse(response, maxSeconds: cap))
        }
        var responses: [String] = []
        var chapters: [Chapter] = []
        for (index, window) in windows.enumerated() {
            let response = try await model.respond(to: window.text)
            responses.append(response)
            let from = index == 0 ? 0 : window.transcript.segments.first?.start ?? 0
            let next = index + 1 < windows.count ? windows[index + 1].transcript.segments.first?.start : nil
            chapters += parseResponse(response, maxSeconds: cap).filter { chapter in
                chapter.start >= from && next.map { chapter.start < $0 } ?? true
            }
        }
        return Markers(responses: responses, chapters: SummaryService.mergeChapters(chapters))
    }

    private static func smartChaptersAsk(firstMarker: String) -> String {
        "Read the transcript below and propose between 4 and 10 chapter markers that capture the major topic shifts. Output only the markers, one per line, in the form 'MM:SS Title' (or 'HH:MM:SS Title' for content over an hour). The first marker MUST start at \(firstMarker). Titles are 3 to 7 plain words — no bullets, no quotes, no commentary."
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
