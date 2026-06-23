import Foundation

public enum CaptionLength: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case short
    case medium
    case long

    public var id: String { rawValue }

    public var maxCharsPerLine: Int? {
        switch self {
        case .none: return nil
        case .short: return 32
        case .medium: return 42
        case .long: return 60
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "As-is"
        case .short: return "Short (reels)"
        case .medium: return "Medium (TV)"
        case .long: return "Long (movie)"
        }
    }
}

enum CaptionWrapper {
    static func wrap(_ text: String, length: CaptionLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit = length.maxCharsPerLine else {
            return trimmed
                .split(whereSeparator: \.isNewline)
                .filter { !$0.allSatisfy(\.isWhitespace) }
                .joined(separator: "\n")
        }
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        return balancedLines(words, limit: limit).joined(separator: "\n")
    }

    // Greedy at the full limit already yields the fewest lines a cue can take; re-wrapping at the
    // narrowest width that still fits in that many lines evens the lengths out, so a long caption
    // doesn't end on an orphaned word — a readability convention for subtitles.
    private static func balancedLines(_ words: [String], limit: Int) -> [String] {
        let greedy = greedyLines(words, width: limit)
        guard greedy.count > 1 else { return greedy }
        var lo = 1
        var hi = limit
        while lo < hi {
            let mid = (lo + hi) / 2
            if greedyLines(words, width: mid).count <= greedy.count {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return greedyLines(words, width: lo)
    }

    private static func greedyLines(_ words: [String], width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
