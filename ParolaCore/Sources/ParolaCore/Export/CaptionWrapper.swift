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
    /// The text with blank lines dropped, since a blank line would end a subtitle cue early.
    static func asIs(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .joined(separator: "\n")
    }
}
