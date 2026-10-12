import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public actor SummaryService {
    public enum FailureReason: LocalizedError, CustomStringConvertible, Sendable {
        case modelError(String)

        public var description: String {
            switch self {
            case .modelError(let reason): return "Summary failed: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    private let budget: TokenBudget
    private let features: FeatureSet
    /// nil means Apple's on-device model, the only path that can answer in Generable form.
    private let makeModel: (@Sendable (String?) async throws -> any LanguageModel)?

    /// A transcript over the budget is summarised per time-window and reduced.
    public init(budget: TokenBudget = .onDevice, features: FeatureSet = .resolve()) {
        self.budget = budget
        self.features = features
        self.makeModel = nil
    }

    /// Summarises through the model `makeModel` builds for the instructions it is handed, instead
    /// of Apple's on-device model. `budget` is that model's, so the windows match what it can take.
    public init(
        budget: TokenBudget,
        features: FeatureSet = .resolve(),
        makeModel: @escaping @Sendable (String?) async throws -> any LanguageModel
    ) {
        self.budget = budget
        self.features = features
        self.makeModel = makeModel
    }

    public func summarise(_ transcript: Transcript) async throws -> Summary {
        try await summarise(transcript, options: .default)
    }

    public func summarise(_ transcript: Transcript, options: SummaryOptions) async throws -> Summary {
        try features.require(.ai)
        #if canImport(FoundationModels)
        if makeModel == nil,
           #available(macOS 26.0, iOS 26.0, visionOS 26.0, *),
           !(await LanguageModelFactory.onDeviceIsMocked()) {
            return try await summariseStructured(transcript, options: options)
        }
        #endif
        return try await summariseText(transcript, options: options)
    }

    public func summarise(_ transcript: Transcript, model: any LanguageModel) async throws -> Summary {
        try features.require(.ai)
        return try await summarise(transcript, model: model, options: .default)
    }

    private func summarise(_ transcript: Transcript, model: any LanguageModel, options: SummaryOptions) async throws -> Summary {
        try await summarise(transcript, options: options, instructions: SummaryService.textInstructions(for: options)) { prompt in
            do {
                return SummaryService.parse(try await model.respond(to: prompt))
            } catch {
                ParolaLog.error(.ai, "summary model failed", [.error: .error(error)])
                throw FailureReason.modelError(error.localizedDescription)
            }
        }
    }

    private func summarise(
        _ transcript: Transcript,
        options: SummaryOptions,
        instructions: String,
        respond: (String) async throws -> Summary
    ) async throws -> Summary {
        var summary = try await summariseInWindows(transcript, options: options, instructions: instructions, respond: respond)
        // A model can write action items it was told to leave out, so the option decides on every path.
        if !options.actionItems { summary.actionItems = [] }
        return summary
    }

    private func summariseInWindows(
        _ transcript: Transcript,
        options: SummaryOptions,
        instructions: String,
        respond: (String) async throws -> Summary
    ) async throws -> Summary {
        let windows = await SummaryService.windows(for: transcript, budget: budget, instructions: instructions, options: options)
        guard windows.count > 1 else {
            return try await respond(SummaryService.buildPrompt(for: transcript, options: options))
        }
        let parts = TranscriptWindows.parts(of: windows, in: transcript)
        var summaries: [Summary] = []
        for (window, part) in zip(windows, parts) {
            summaries.append(try await respond(SummaryService.buildPrompt(for: window.transcript, options: options, part: part)))
        }
        let reduced = try await reduce(summaries.map(\.text), instructions: instructions, respond: respond)
        return Summary(
            text: reduced.text,
            chapters: SummaryService.thinChapters(
                SummaryService.mergeChapters(summaries.flatMap(\.chapters)),
                end: transcript.segments.map(\.end).max() ?? 0
            ),
            actionItems: SummaryService.mergeActionItems(summaries.flatMap(\.actionItems) + reduced.actionItems)
        )
    }

    /// One reduce call when the parts fit together, otherwise each half is reduced first.
    private func reduce(
        _ texts: [String],
        instructions: String,
        respond: (String) async throws -> Summary
    ) async throws -> Summary {
        let prompt = SummaryService.buildReducePrompt(texts)
        let limit = await TranscriptWindows.inputLimit(budget: budget, instructions: instructions, answer: .brief)
        guard texts.count > 2, !(await budget.fits(prompt, within: limit)) else {
            return try await respond(prompt)
        }
        let middle = texts.count / 2
        let head = try await reduce(Array(texts[..<middle]), instructions: instructions, respond: respond)
        let tail = try await reduce(Array(texts[middle...]), instructions: instructions, respond: respond)
        let joined = try await respond(SummaryService.buildReducePrompt([head.text, tail.text]))
        return Summary(
            text: joined.text,
            actionItems: SummaryService.mergeActionItems(head.actionItems + tail.actionItems + joined.actionItems)
        )
    }

    private func summariseText(_ transcript: Transcript, options: SummaryOptions) async throws -> Summary {
        let instructions = SummaryService.textInstructions(for: options)
        let model: any LanguageModel
        if let makeModel {
            model = try await makeModel(instructions)
        } else {
            model = try await LanguageModelFactory.makeOnDevice(instructions: instructions)
        }
        return try await summarise(transcript, model: model, options: options)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private func summariseStructured(_ transcript: Transcript, options: SummaryOptions) async throws -> Summary {
        try LanguageModelFactory.requireOnDevice()
        let instructions = SummaryService.structuredInstructions(for: options)
        return try await summarise(transcript, options: options, instructions: instructions) { prompt in
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: GenerableSummary.self)
                return response.content.toSummary()
            } catch {
                ParolaLog.error(.ai, "on-device summary model failed", [.error: .error(error)])
                throw FailureReason.modelError(error.localizedDescription)
            }
        }
    }
    #endif

    static func line(for segment: TranscriptSegment, options: SummaryOptions) -> String? {
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let speakerPrefix: String
        if options.includeSpeakers,
           let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !speaker.isEmpty {
            speakerPrefix = "\(speaker): "
        } else {
            speakerPrefix = ""
        }
        guard options.includeTimestamps else {
            return "\(speakerPrefix)\(body)\n"
        }
        return "\(Timecode.format(segment.start))  \(speakerPrefix)\(body)\n"
    }

    static func textInstructions(for options: SummaryOptions) -> String {
        var out = textInstructionsBase
        if options.actionItems {
            out += "\n\nACTION ITEMS:\nOne action per line starting with '- '."
        }
        out += optionSentences(for: options)
        return out
    }

    static func structuredInstructions(for options: SummaryOptions) -> String {
        var out = structuredInstructionsBase
        if !options.actionItems {
            out += "\n\nLeave actionItems empty."
        }
        out += optionSentences(for: options)
        return out
    }

    private static func optionSentences(for options: SummaryOptions) -> String {
        var sentences: [String] = []
        if options.sections {
            sentences.append("Organise the summary under two to four short section headings.")
        }
        if options.bulletPoints {
            sentences.append("Write the summary as bullet points.")
        }
        if options.keyPointsOnly {
            sentences.append("Give only the key points, no narrative.")
        }
        if let code = options.outputLanguage {
            // The instruction around it is English, so the language is named in English too.
            let name = Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code) ?? code
            sentences.append("Write everything in \(name).")
        }
        if let customPrompt = options.customPrompt, !customPrompt.isEmpty {
            sentences.append("Additional instructions: \(customPrompt)")
        }
        guard !sentences.isEmpty else { return "" }
        return "\n\n" + sentences.joined(separator: " ")
    }

    private static let textInstructionsBase = """
    You summarise transcripts. Always respond with exactly two sections:

    SUMMARY:
    A two-to-four-sentence paragraph in plain prose. No bullet points, no headings inside the paragraph.

    CHAPTERS:
    One line per chapter, in the form "MM:SS  Short title". Three to six words for the title. Five to ten chapters total, fewer if the transcript is short.
    """

    private static let structuredInstructionsBase = """
    You summarise transcripts. Produce a two-to-four-sentence summary plus five to ten chapter markers. Each chapter has a timestamp in seconds from the start of the transcript and a three-to-six-word title.
    """

    static let promptHeader = "Transcript follows. Each line is prefixed with its timestamp.\n\n"

    static func buildPrompt(for transcript: Transcript, options: SummaryOptions = .default, part: TranscriptWindows.Part? = nil) -> String {
        let note = part.map { "This is part \($0.index) of \($0.count) of a longer transcript. Mark \($0.chapters) chapter\($0.chapters == 1 ? "" : "s") for this part only.\n" } ?? ""
        return note + promptHeader + transcript.segments.compactMap { line(for: $0, options: options) }.joined()
    }

    static func windows(
        for transcript: Transcript,
        budget: TokenBudget,
        instructions: String,
        options: SummaryOptions = .default
    ) async -> [TranscriptWindows.Window] {
        await TranscriptWindows.split(
            transcript,
            budget: budget,
            instructions: instructions,
            line: { line(for: $0, options: options) },
            render: { buildPrompt(for: $0, options: options, part: .widest) }
        )
    }

    static func buildReducePrompt(_ partSummaries: [String]) -> String {
        var out = "These are summaries of consecutive parts of one longer transcript, in order. Combine them into a single summary of the whole transcript, in the same response format.\n"
        for (index, part) in partSummaries.enumerated() {
            out += "\nPart \(index + 1):\n\(part)\n"
        }
        return out
    }

    static func mergeChapters(_ chapters: [Chapter], echoWindowSeconds: Double = 600) -> [Chapter] {
        var out: [Chapter] = []
        for chapter in chapters.sorted(by: { $0.start < $1.start }) {
            if let last = out.last,
               last.title.compare(chapter.title, options: .caseInsensitive) == .orderedSame,
               chapter.start - last.start <= echoWindowSeconds {
                continue
            }
            out.append(chapter)
        }
        return out
    }

    /// Drops the chapter whose neighbours sit closest until `limit` are left, so the rest split the timeline evenly.
    static func thinChapters(_ chapters: [Chapter], to limit: Int = TranscriptWindows.chapterLimit, end: Double) -> [Chapter] {
        var kept = chapters.sorted { $0.start < $1.start }
        while kept.count > max(1, limit) {
            var drop = 1
            var narrowest = Double.infinity
            for index in 1..<kept.count {
                let after = index + 1 < kept.count ? kept[index + 1].start : max(end, kept[index].start)
                let span = after - kept[index - 1].start
                if span < narrowest {
                    narrowest = span
                    drop = index
                }
            }
            kept.remove(at: drop)
        }
        return kept
    }

    static func mergeActionItems(_ items: [String]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    static func parse(_ raw: String) -> Summary {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var summaryParagraphs: [[String]] = []
        var currentParagraph: [String] = []
        var chapters: [Chapter] = []
        var actionItems: [String] = []

        enum Section { case summary, chapters, actionItems }
        // A reply that never says SUMMARY: is all summary — small local models drop the header under
        // extra instructions. An explicit SUMMARY: section replaces whatever came before it.
        var section: Section = .summary
        var sawSummaryHeader = false

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                summaryParagraphs.append(currentParagraph)
                currentParagraph = []
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Models often wrap the section header in markdown ("**SUMMARY:**", "## CHAPTERS:").
            let header = line.drop(while: { "#*_ ".contains($0) })
            if header.uppercased().hasPrefix("SUMMARY:") {
                if !sawSummaryHeader {
                    sawSummaryHeader = true
                    summaryParagraphs.removeAll()
                    currentParagraph.removeAll()
                }
                section = .summary
                let remainder = header.dropFirst("SUMMARY:".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " *_"))
                if !remainder.isEmpty { currentParagraph.append(remainder) }
                continue
            }
            if header.uppercased().hasPrefix("CHAPTERS:") {
                flushParagraph()
                section = .chapters
                continue
            }
            if header.uppercased().hasPrefix("ACTION ITEMS:") {
                flushParagraph()
                section = .actionItems
                continue
            }

            switch section {
            case .summary:
                if line.isEmpty {
                    flushParagraph()
                } else {
                    currentParagraph.append(line)
                }
            case .chapters:
                guard let chapter = SummaryService.parseChapter(line) else { continue }
                chapters.append(chapter)
            case .actionItems:
                let item = line.drop(while: { "-•* ".contains($0) }).trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { continue }
                actionItems.append(item)
            }
        }
        flushParagraph()

        let summaryText = summaryParagraphs
            .map { $0.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespaces)
        return Summary(text: summaryText, chapters: chapters, actionItems: actionItems)
    }

    static func parseChapter(_ line: String) -> Chapter? {
        guard !line.isEmpty else { return nil }
        let scanner = SmartChapters.stripLeadingMarkers(line)

        let parts = scanner.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2 else { return nil }
        let timeToken = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*_[]()`"))
        guard let seconds = SummaryService.parseClock(timeToken) else { return nil }
        return Chapter.cleaned(title: String(parts[1]), start: seconds)
    }

    static func parseClock(_ s: String) -> Double? {
        Format.parseClockTimestamp(s)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable
struct GenerableSummary: Sendable {
    @Guide(description: "Two to four sentences in plain prose. No bullet points.")
    var summary: String

    @Guide(description: "Five to ten chapter markers covering the transcript in order.")
    var chapters: [GenerableChapter]

    @Guide(description: "Concrete action items, one per entry; empty when none.")
    var actionItems: [String]

    func toSummary() -> Summary {
        Summary(
            text: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters.compactMap { Chapter.cleaned(title: $0.title, start: $0.startSeconds) },
            actionItems: actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable
struct GenerableChapter: Sendable {
    @Guide(description: "Seconds from the start of the transcript.")
    var startSeconds: Double

    @Guide(description: "Three to six words.")
    var title: String
}
#endif
