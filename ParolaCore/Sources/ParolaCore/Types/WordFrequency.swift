import Foundation

public enum WordFrequency {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { word }
        public let word: String
        public let count: Int
    }

    public static let defaultStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "while",
        "of", "at", "by", "for", "with", "about", "against", "between", "into", "through",
        "during", "before", "after", "above", "below", "to", "from", "up", "down", "in",
        "out", "on", "off", "over", "under", "again", "further", "then", "once",
        "here", "there", "all", "any", "both", "each", "few", "more", "most", "other",
        "some", "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "having",
        "do", "does", "did", "doing", "will", "would", "should", "could", "shall", "may",
        "might", "must", "can",
        "this", "that", "these", "those", "i", "me", "my", "we", "our", "you", "your",
        "he", "him", "his", "she", "her", "it", "its", "they", "them", "their", "what",
        "which", "who", "whom", "as", "just", "really", "very", "also",
    ]

    public static func compute(
        text: String,
        limit: Int = 20,
        minLength: Int = 2,
        stopWords: Set<String> = defaultStopWords
    ) -> [Entry] {
        var counts: [String: Int] = [:]
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(raw).lowercased()
            guard token.count >= minLength else { continue }
            guard !stopWords.contains(token) else { continue }
            counts[token, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        .prefix(limit)
        .map { Entry(word: $0.key, count: $0.value) }
    }
}
