import Foundation
import NaturalLanguage

public actor LibrarySearchIndex {
    public struct Match: Sendable, Equatable {
        public let entryID: String
        public let score: Int
        public let snippet: String
    }

    private struct IndexedEntry: Codable {
        let id: String
        let title: String
        let text: String
    }

    private struct Snapshot: Codable {
        let entries: [String: IndexedEntry]
        let inverted: [String: [String]]
    }

    private var entries: [String: IndexedEntry]
    private var inverted: [String: Set<String>]
    private let indexURL: URL

    public init(indexURL: URL) {
        self.indexURL = indexURL
        if let data = try? Data(contentsOf: indexURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.entries = snapshot.entries
            self.inverted = snapshot.inverted.mapValues { Set($0) }
        } else {
            self.entries = [:]
            self.inverted = [:]
        }
    }

    public func index(id: String, title: String, text: String, createdAt: Date) {
        removeFromIndex(id)
        entries[id] = IndexedEntry(id: id, title: title, text: text)
        let tokens = Self.tokenize(title) + Self.tokenize(text)
        for token in Set(tokens) {
            inverted[token, default: []].insert(id)
        }
        saveSnapshot()
    }

    public func remove(_ id: String) {
        removeFromIndex(id)
        saveSnapshot()
    }

    public func search(_ query: String) -> [Match] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var scores: [String: Int] = [:]
        for queryToken in queryTokens {
            for (indexToken, ids) in inverted where indexToken.hasPrefix(queryToken) {
                for id in ids { scores[id, default: 0] += 1 }
            }
        }

        return scores
            .sorted { $0.value > $1.value }
            .compactMap { (id, score) -> Match? in
                guard let entry = entries[id] else { return nil }
                return Match(
                    entryID: id,
                    score: score,
                    snippet: Self.makeSnippet(text: entry.text, tokens: queryTokens)
                )
            }
    }

    public func entryIDs() -> Set<String> {
        Set(entries.keys)
    }

    private func removeFromIndex(_ id: String) {
        entries.removeValue(forKey: id)
        for (token, ids) in inverted {
            var copy = ids
            copy.remove(id)
            if copy.isEmpty {
                inverted.removeValue(forKey: token)
            } else {
                inverted[token] = copy
            }
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range].lowercased()
            if token.count > 1 { tokens.append(token) }
            return true
        }
        return tokens
    }

    private static func makeSnippet(text: String, tokens: [String]) -> String {
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()
        for token in tokens {
            if let range = lower.range(of: token) {
                let lowerIdx = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let upperIdx = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                return String(text[lowerIdx..<upperIdx])
            }
        }
        return String(text.prefix(80))
    }

    private func saveSnapshot() {
        let snapshot = Snapshot(
            entries: entries,
            inverted: inverted.mapValues { Array($0).sorted() }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
