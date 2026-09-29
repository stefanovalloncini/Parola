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
        try await markers(for: transcript, model: model, budget: budget, wholeCount: "between 4 and 10", ask: smartChaptersAsk).chapters
    }

    struct Markers {
        let responses: [String]
        let chapters: [Chapter]
    }

    /// What a chapter prompt asks for: where the first marker goes and how many markers to write.
    struct Ask {
        let firstMarker: String
        let markers: String
        let part: TranscriptWindows.Part?

        static let widest = Ask(firstMarker: "99:59:59", markers: "between 99 and 99", part: .widest)
    }

    static func markers(
        for transcript: Transcript,
        model: any LanguageModel,
        budget: TokenBudget,
        wholeCount: String,
        ask: (Ask) -> String
    ) async throws -> Markers {
        func prompt(_ window: Transcript, _ request: Ask) -> String {
            ask(request) + "\n\nTranscript:\n" + TranscriptPromptContext.timestampedLines(for: window)
        }
        let windows = await TranscriptWindows.split(
            transcript,
            budget: budget,
            instructions: LanguageModelFactory.defaultInstructions,
            line: TranscriptPromptContext.timestampedLine(for:),
            render: { prompt($0, .widest) }
        )
        let cap = transcript.segments.map(\.end).max()
        guard windows.count > 1 else {
            let response = try await model.respond(to: prompt(transcript, Ask(firstMarker: "00:00", markers: wholeCount, part: nil)))
            return Markers(responses: [response], chapters: parseResponse(response, maxSeconds: cap))
        }
        var responses: [String] = []
        var chapters: [Chapter] = []
        for (index, (window, part)) in zip(windows, TranscriptWindows.parts(of: windows, in: transcript)).enumerated() {
            let from = index == 0 ? 0 : window.transcript.segments.first?.start ?? 0
            let request = Ask(firstMarker: Timecode.format(from), markers: "\(part.chapters)", part: part)
            let response = try await model.respond(to: prompt(window.transcript, request))
            responses.append(response)
            let next = index + 1 < windows.count ? windows[index + 1].transcript.segments.first?.start : nil
            chapters += parseResponse(response, maxSeconds: cap).filter { chapter in
                chapter.start >= from && next.map { chapter.start < $0 } ?? true
            }
        }
        let merged = SummaryService.mergeChapters(chapters)
        return Markers(responses: responses, chapters: SummaryService.thinChapters(merged, end: cap ?? 0))
    }

    static func partNote(_ part: TranscriptWindows.Part?) -> String {
        part.map { "This is part \($0.index) of \($0.count) of a longer transcript. " } ?? ""
    }

    private static func smartChaptersAsk(_ ask: Ask) -> String {
        partNote(ask.part) + "Read the transcript below and propose \(ask.markers) chapter markers that capture the major topic shifts. Output only the markers, one per line, in the form 'MM:SS Title' (or 'HH:MM:SS Title' for content over an hour). The first marker MUST start at \(ask.firstMarker). Titles are 3 to 7 plain words — no bullets, no quotes, no commentary."
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
