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

    /// The budget is the prompt-token ceiling (bytes/4 estimate); transcripts over it are
    /// summarised per time-window and reduced. The default fits Apple's 4096-token context.
    public init(budgetTokens: Int = SummaryService.defaultBudgetTokens, features: FeatureSet = .resolve()) {
        self.budgetTokens = budgetTokens
        self.features = features
    }

    public func summarise(_ transcript: Transcript) async throws -> Summary {
        try features.require(.ai)
        #if canImport(FoundationModels)
        // The structured path talks to FoundationModels directly, so it can't see an installed
        // mock — route mocked runs through the text path, which resolves models via the factory.
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *),
           await MockLanguageModelStore.shared.resolve(for: .foundation) == nil {
            return try await summariseStructured(transcript)
        }
        #endif
        return try await summariseText(transcript)
    }

    public func summarise(_ transcript: Transcript, model: any LanguageModel) async throws -> Summary {
        try features.require(.ai)
        return try await summarise(transcript) { prompt in
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
        respond: (String) async throws -> Summary
    ) async throws -> Summary {
        let lines = transcript.segments.map(TranscriptPromptContext.timestampedLine(for:))
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
        return Summary(text: reduced.text, chapters: SummaryService.mergeChapters(parts.flatMap(\.chapters)))
    }

    private func summariseText(_ transcript: Transcript) async throws -> Summary {
        let model = try await LanguageModelFactory.makeOnDevice(instructions: SummaryService.textInstructions)
        return try await summarise(transcript, model: model)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private func summariseStructured(_ transcript: Transcript) async throws -> Summary {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FailureReason.notAvailable(LanguageModelFactory.unavailableMessage(for: reason))
        @unknown default:
            throw FailureReason.notAvailable("Apple Intelligence isn't available right now.")
        }

        return try await summarise(transcript) { prompt in
            let session = LanguageModelSession(instructions: SummaryService.structuredInstructions)
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

    static let textInstructions = """
    You summarise transcripts. Always respond with exactly two sections:

    SUMMARY:
    A two-to-four-sentence paragraph in plain prose. No bullet points, no headings inside the paragraph.

    CHAPTERS:
    One line per chapter, in the form "MM:SS  Short title". Three to six words for the title. Five to ten chapters total, fewer if the transcript is short.
    """

    static let structuredInstructions = """
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

    static func parse(_ raw: String) -> Summary {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var summaryParagraphs: [[String]] = []
        var currentParagraph: [String] = []
        var chapters: [Chapter] = []

        enum Section { case none, summary, chapters }
        var section: Section = .none

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

            switch section {
            case .none:
                continue
            case .summary:
                if line.isEmpty {
                    flushParagraph()
                } else {
                    currentParagraph.append(line)
                }
            case .chapters:
                guard let chapter = SummaryService.parseChapter(line) else { continue }
                chapters.append(chapter)
            }
        }
        flushParagraph()

        let summaryText = summaryParagraphs
            .map { $0.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespaces)
        return Summary(text: summaryText, chapters: chapters)
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

    func toSummary() -> Summary {
        Summary(
            text: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters.compactMap { Chapter.cleaned(title: $0.title, start: $0.startSeconds) }
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
