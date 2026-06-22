import Foundation
import NaturalLanguage

public actor LibrarySearchIndex {
    public struct Highlight: Sendable, Equatable {
        public let start: Int
        public let length: Int

        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    public struct Match: Sendable, Equatable {
        public let entryID: String
        public let score: Int
        public let snippet: String
        public let highlights: [Highlight]

        public init(entryID: String, score: Int, snippet: String, highlights: [Highlight] = []) {
            self.entryID = entryID
            self.score = score
            self.snippet = snippet
            self.highlights = highlights
        }
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
    private let saveDebounce: Duration
    private let clock: any Clock<Duration>
    private var pendingSaveTask: Task<Void, Never>?

    public init(
        indexURL: URL,
        saveDebounce: Duration = .milliseconds(250),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.indexURL = indexURL
        self.saveDebounce = saveDebounce
        self.clock = clock
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
        scheduleSave()
    }

    public func remove(_ id: String) {
        removeFromIndex(id)
        scheduleSave()
    }

    public func search(_ query: String) -> [Match] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var scores: [String: Int] = [:]
        for queryToken in Set(queryTokens) {
            for (indexToken, ids) in inverted where indexToken.hasPrefix(queryToken) {
                for id in ids { scores[id, default: 0] += 1 }
            }
        }

        return scores
            .sorted { $0.value > $1.value }
            .compactMap { (id, score) -> Match? in
                guard let entry = entries[id] else { return nil }
                let snippet = Self.makeSnippet(text: entry.text, tokens: queryTokens)
                return Match(
                    entryID: id,
                    score: score,
                    snippet: snippet.text,
                    highlights: snippet.highlights
                )
            }
    }

    /// Writes any pending debounced snapshot to disk. Call before app termination.
    public func flush() async {
        let task = pendingSaveTask
        pendingSaveTask = nil
        task?.cancel()
        saveSnapshot()
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

    private static func makeSnippet(text: String, tokens: [String]) -> (text: String, highlights: [Highlight]) {
        guard !text.isEmpty else { return ("", []) }
        var firstHit: Range<String.Index>?
        for token in tokens {
            if let range = text.range(of: token, options: .caseInsensitive) {
                firstHit = range
                break
            }
        }
        let snippetRange: Range<String.Index>
        if let firstHit {
            let lowerIdx = text.index(firstHit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let upperIdx = text.index(firstHit.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            snippetRange = lowerIdx..<upperIdx
        } else {
            snippetRange = text.startIndex..<(text.index(text.startIndex, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex)
        }
        let snippet = String(text[snippetRange])
        var highlights: [Highlight] = []
        for token in Set(tokens) {
            var cursor = snippet.startIndex
            while let hit = snippet.range(of: token, options: .caseInsensitive, range: cursor..<snippet.endIndex) {
                let start = snippet.distance(from: snippet.startIndex, to: hit.lowerBound)
                let length = snippet.distance(from: hit.lowerBound, to: hit.upperBound)
                highlights.append(Highlight(start: start, length: length))
                cursor = hit.upperBound
            }
        }
        highlights.sort { $0.start < $1.start }
        return (snippet, mergeOverlapping(highlights))
    }

    private static func mergeOverlapping(_ highlights: [Highlight]) -> [Highlight] {
        guard !highlights.isEmpty else { return [] }
        var merged: [Highlight] = []
        for h in highlights {
            if let last = merged.last, h.start <= last.start + last.length {
                let end = max(last.start + last.length, h.start + h.length)
                merged.removeLast()
                merged.append(Highlight(start: last.start, length: end - last.start))
            } else {
                merged.append(h)
            }
        }
        return merged
    }

    private func scheduleSave() {
        if pendingSaveTask != nil { return }
        let debounce = saveDebounce
        let clock = clock
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce, clock: clock)
            if Task.isCancelled { return }
            await self?.persistAfterDebounce()
        }
    }

    private func persistAfterDebounce() {
        pendingSaveTask = nil
        saveSnapshot()
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
