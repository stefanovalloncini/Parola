import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Wraps Apple's Foundation Models on-device LLM to produce transcript summaries + chapter markers.
///
/// macOS 26 / iOS 26 only. Earlier OSes get a `.notAvailable` error — caller should hide the feature.
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
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return try await summariseUsingFoundationModels(transcript)
        } else {
            throw FailureReason.notAvailable("Foundation Models requires macOS 26 / iOS 26 or newer.")
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private func summariseUsingFoundationModels(_ transcript: Transcript) async throws -> Summary {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FailureReason.notAvailable("On-device language model is not available (\(reason)).")
        @unknown default:
            throw FailureReason.notAvailable("On-device language model availability is unknown.")
        }

        let prompt = SummaryService.buildPrompt(for: transcript)
        let session = LanguageModelSession(
            instructions: """
            You summarise transcripts. Always respond with exactly two sections:

            SUMMARY:
            A two-to-four-sentence paragraph in plain prose. No bullet points, no headings inside the paragraph.

            CHAPTERS:
            One line per chapter, in the form "MM:SS  Short title". Three to six words for the title. Five to ten chapters total, fewer if the transcript is short.
            """
        )

        do {
            let response = try await session.respond(to: prompt)
            return SummaryService.parse(response.content)
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
        }
    }

    static func buildPrompt(for transcript: Transcript) -> String {
        var out = "Transcript follows. Each line is prefixed with its timestamp.\n\n"
        for segment in transcript.segments {
            out += "\(SummaryService.formatTimestamp(segment.start))  \(segment.text.trimmingCharacters(in: .whitespaces))\n"
        }
        return out
    }

    static func parse(_ raw: String) -> Summary {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var summaryLines: [String] = []
        var chapters: [Chapter] = []

        enum Section { case none, summary, chapters }
        var section: Section = .none

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("SUMMARY:") {
                section = .summary
                let remainder = line.dropFirst("SUMMARY:".count).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty { summaryLines.append(remainder) }
                continue
            }
            if line.uppercased().hasPrefix("CHAPTERS:") {
                section = .chapters
                continue
            }

            switch section {
            case .none:
                continue
            case .summary:
                if line.isEmpty {
                    if !summaryLines.isEmpty { section = .none }
                } else {
                    summaryLines.append(line)
                }
            case .chapters:
                guard let chapter = SummaryService.parseChapter(line) else { continue }
                chapters.append(chapter)
            }
        }

        let summaryText = summaryLines
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Summary(text: summaryText, chapters: chapters)
    }

    static func parseChapter(_ line: String) -> Chapter? {
        guard !line.isEmpty else { return nil }
        var scanner = line[...]

        if scanner.first == "-" || scanner.first == "*" {
            scanner = scanner.dropFirst().drop(while: { $0 == " " })
        }

        let parts = scanner.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let timeToken = String(parts[0])
        let title = parts[1].trimmingCharacters(in: .whitespaces)
        guard let seconds = SummaryService.parseClock(timeToken), !title.isEmpty else { return nil }
        return Chapter(title: title, start: seconds)
    }

    static func parseClock(_ s: String) -> Double? {
        let bits = s.split(separator: ":").map(String.init)
        switch bits.count {
        case 2:
            guard let m = Int(bits[0]), let sec = Double(bits[1]) else { return nil }
            return Double(m) * 60 + sec
        case 3:
            guard let h = Int(bits[0]), let m = Int(bits[1]), let sec = Double(bits[2]) else { return nil }
            return Double(h) * 3600 + Double(m) * 60 + sec
        default:
            return nil
        }
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
#else
/// Stub for platforms without FoundationModels (theoretically unreachable on iOS 17 / macOS 14).
public actor SummaryService {
    public enum FailureReason: LocalizedError, CustomStringConvertible, Sendable {
        case notAvailable(String)
        public var description: String {
            switch self { case .notAvailable(let r): return "Summary unavailable: \(r)" }
        }
        public var errorDescription: String? { description }
    }
    public init() {}
    public func summarise(_ transcript: Transcript) async throws -> Summary {
        throw FailureReason.notAvailable("FoundationModels not available in this build.")
    }
}
#endif
