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

    public init() {}

    public func summarise(_ transcript: Transcript) async throws -> Summary {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return try await summariseStructured(transcript)
        }
        #endif
        return try await summariseText(transcript)
    }

    public func summarise(_ transcript: Transcript, model: any LanguageModel) async throws -> Summary {
        let prompt = SummaryService.buildPrompt(for: transcript)
        do {
            let response = try await model.respond(to: prompt)
            return SummaryService.parse(response)
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
        }
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

        let session = LanguageModelSession(instructions: SummaryService.structuredInstructions)
        let prompt = SummaryService.buildPrompt(for: transcript)
        do {
            let response = try await session.respond(to: prompt, generating: GenerableSummary.self)
            return response.content.toSummary()
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
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

    static func buildPrompt(for transcript: Transcript) -> String {
        var out = "Transcript follows. Each line is prefixed with its timestamp.\n\n"
        out += TranscriptPromptContext.timestampedLines(for: transcript)
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
        var scanner = line[...]

        if scanner.first == "-" || scanner.first == "*" || scanner.first == "•" {
            scanner = scanner.dropFirst().drop(while: { $0 == " " })
        }

        let parts = scanner.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2 else { return nil }
        let timeToken = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*_[]()`"))
        let title = ChapterTitle.clean(String(parts[1]))
        guard let seconds = SummaryService.parseClock(timeToken), !title.isEmpty else { return nil }
        return Chapter(title: title, start: seconds)
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
            chapters: chapters.map { Chapter(title: $0.title, start: $0.startSeconds) }
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
