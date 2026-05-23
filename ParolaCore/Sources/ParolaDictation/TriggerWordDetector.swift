import Foundation
import ParolaCore

public struct TriggerWordDetector: Sendable {
    public struct Match: Sendable, Hashable {
        public let promptID: UUID
        public let cleanedText: String

        public init(promptID: UUID, cleanedText: String) {
            self.promptID = promptID
            self.cleanedText = cleanedText
        }
    }

    public init() {}

    public func detect(_ text: String, against prompts: [Prompt]) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let stripped = stripBoundary(from: trimmed, leading: false, trailing: true)
        let leadingHaystack = trimmed.lowercased()
        let trailingHaystack = stripped.lowercased()

        for prompt in prompts {
            for word in prompt.triggerWords {
                let needle = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !needle.isEmpty else { continue }
                if let cleaned = stripLeading(needle, from: trimmed, loweredHaystack: leadingHaystack) {
                    return Match(promptID: prompt.id, cleanedText: cleaned)
                }
                if let cleaned = stripTrailing(needle, from: stripped, loweredHaystack: trailingHaystack) {
                    return Match(promptID: prompt.id, cleanedText: cleaned)
                }
            }
        }
        return nil
    }

    private func stripBoundary(from text: String, leading: Bool, trailing: Bool) -> String {
        var start = text.startIndex
        var end = text.endIndex
        if leading {
            while start < end && isBoundary(text[start]) {
                start = text.index(after: start)
            }
        }
        if trailing {
            while end > start {
                let prev = text.index(before: end)
                guard isBoundary(text[prev]) else { break }
                end = prev
            }
        }
        return String(text[start..<end])
    }

    private func stripLeading(_ needle: String, from text: String, loweredHaystack: String) -> String? {
        guard loweredHaystack.hasPrefix(needle) else { return nil }
        let after = text.index(text.startIndex, offsetBy: needle.count)
        guard after == text.endIndex || isBoundary(text[after]) else { return nil }
        var idx = after
        while idx < text.endIndex && (text[idx].isWhitespace || Self.boundaryPunctuation.contains(text[idx])) {
            idx = text.index(after: idx)
        }
        return String(text[idx...])
    }

    private func stripTrailing(_ needle: String, from text: String, loweredHaystack: String) -> String? {
        guard loweredHaystack.hasSuffix(needle) else { return nil }
        let start = text.index(text.endIndex, offsetBy: -needle.count)
        guard start == text.startIndex || isBoundary(text[text.index(before: start)]) else { return nil }
        var idx = start
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]
            guard ch.isWhitespace || Self.boundaryPunctuation.contains(ch) else { break }
            idx = prev
        }
        return String(text[..<idx])
    }

    private func isBoundary(_ ch: Character) -> Bool {
        ch.isWhitespace || Self.boundaryPunctuation.contains(ch)
    }

    private static let boundaryPunctuation: Set<Character> = [",", ".", ":", ";", "!", "?"]
}
