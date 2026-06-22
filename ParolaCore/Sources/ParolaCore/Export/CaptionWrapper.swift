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
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
