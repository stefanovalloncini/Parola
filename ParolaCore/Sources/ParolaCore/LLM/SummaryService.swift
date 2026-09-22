import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public actor SummaryService {
    public enum FailureReason: LocalizedError, CustomStringConvertible, Sendable {
        case notAvailable(String)
        case modelError(String)

        public var description: String {
            switch self {
            case .notAvailable(let reason): return "Summary unavailable: \(reason)"
            case .modelError(let reason): return "Summary failed: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    public static let defaultBudgetTokens = 3500

    private let budgetTokens: Int
    private let features: FeatureSet
    /// nil means Apple's on-device model, the only path that can answer in Generable form.
    private let makeModel: (@Sendable (String?) async throws -> any LanguageModel)?

    /// The budget is the prompt-token ceiling (bytes/4 estimate); transcripts over it are
    /// summarised per time-window and reduced. The default fits Apple's 4096-token context.
    public init(budgetTokens: Int = SummaryService.defaultBudgetTokens, features: FeatureSet = .resolve()) {
        self.budgetTokens = budgetTokens
        self.features = features
        self.makeModel = nil
    }

    /// Summarises through the model `makeModel` builds for the instructions it is handed, instead
    /// of Apple's on-device model.
    public init(
        budgetTokens: Int = SummaryService.defaultBudgetTokens,
        features: FeatureSet = .resolve(),
        makeModel: @escaping @Sendable (String?) async throws -> any LanguageModel
    ) {
        self.budgetTokens = budgetTokens
        self.features = features
        self.makeModel = makeModel
    }

    public func summarise(_ transcript: Transcript) async throws -> Summary {
        try await summarise(transcript, options: .default)
    }

    public func summarise(_ transcript: Transcript, options: SummaryOptions) async throws -> Summary {
        try features.require(.ai)
        #if canImport(FoundationModels)
        // The structured path talks to FoundationModels directly, so it can't see an installed
        // mock — route mocked runs through the text path, which resolves models via the factory.
        if makeModel == nil,
           #available(macOS 26.0, iOS 26.0, visionOS 26.0, *),
           await MockLanguageModelStore.shared.resolve(for: .foundation) == nil {
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
        try await summarise(transcript, options: options) { prompt in
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
        respond: (String) async throws -> Summary
    ) async throws -> Summary {
        let lines = transcript.segments.map { SummaryService.line(for: $0, options: options) }
        let prompt = SummaryService.promptHeader + lines.compactMap { $0 }.joined()
        guard TokenBudget.estimateTokens(prompt) > budgetTokens else {
            return try await respond(prompt)
        }
        let windows = SummaryService.windowPrompts(for: transcript, lines: lines, budgetTokens: budgetTokens)
        var parts: [Summary] = []
        for window in windows {
            parts.append(try await respond(window.prompt))
        }
        let reduced = try await respond(SummaryService.buildReducePrompt(parts.map(\.text)))
        return Summary(
            text: reduced.text,
            chapters: SummaryService.mergeChapters(parts.flatMap(\.chapters)),
            actionItems: SummaryService.mergeActionItems(parts.flatMap(\.actionItems) + reduced.actionItems)
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
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FailureReason.notAvailable(LanguageModelFactory.unavailableMessage(for: reason))
        @unknown default:
            throw FailureReason.notAvailable("Apple Intelligence isn't available right now.")
        }

        return try await summarise(transcript, options: options) { prompt in
            let session = LanguageModelSession(instructions: SummaryService.structuredInstructions(for: options))
            do {
                let response = try await session.respond(to: prompt, generating: GenerableSummary.self)
                var summary = response.content.toSummary()
                if !options.actionItems { summary.actionItems = [] }
                return summary
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

    static func buildPrompt(for transcript: Transcript) -> String {
        promptHeader + TranscriptPromptContext.timestampedLines(for: transcript)
    }

    static func windows(for transcript: Transcript, budgetTokens: Int) -> [Transcript] {
        windowPrompts(
            for: transcript,
            lines: transcript.segments.map(TranscriptPromptContext.timestampedLine(for:)),
            budgetTokens: budgetTokens
        ).map(\.transcript)
    }

    static func windowPrompts(
        for transcript: Transcript,
        lines: [String?],
        budgetTokens: Int
    ) -> [(transcript: Transcript, prompt: String)] {
        let lineBudget = max(1, budgetTokens - TokenBudget.estimateTokens(promptHeader))
        var windows: [(transcript: Transcript, prompt: String)] = []
        var current: [TranscriptSegment] = []
        var body = ""
        var used = 0

        func close() {
            guard !current.isEmpty else { return }
            windows.append((
                Transcript(segments: current, language: transcript.language, modelName: transcript.modelName),
                promptHeader + body
            ))
            current = []
            body = ""
            used = 0
        }

        for (segment, line) in zip(transcript.segments, lines) {
            let cost = line.map(TokenBudget.estimateTokens) ?? 0
            if !current.isEmpty && used + cost > lineBudget { close() }
            current.append(segment)
            if let line { body += line }
            used += cost
        }
        close()
        return windows
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
