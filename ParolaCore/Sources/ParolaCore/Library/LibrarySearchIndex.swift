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

    struct RebuildEntry: Sendable {
        let id: String
        let title: String
        let text: String
        let auxiliaryText: String

        init(id: String, title: String, text: String, auxiliaryText: String = "") {
            self.id = id
            self.title = title
            self.text = text
            self.auxiliaryText = auxiliaryText
        }
    }

    private struct IndexedEntry: Sendable {
        let title: String
        let excerpt: String
        let tokens: Set<String>
    }

    private struct SnapshotEntry: Codable {
        let title: String
        let excerpt: String
        let tokens: [String]
    }

    private struct Snapshot: Codable {
        let version: Int
        let entries: [String: SnapshotEntry]
    }

    private struct LoadedState: Sendable {
        let entries: [String: IndexedEntry]
        let inverted: [String: Set<String>]
    }

    private enum LoadOutcome: Sendable {
        case loaded(LoadedState)
        case staleDiscarded
        case missing
    }

    private enum RebuildNeed: Sendable {
        case none
        case staleSnapshot
        case absentSnapshot
    }

    private static let snapshotVersion = 3
    private static let excerptLength = 200

    private var entries: [String: IndexedEntry] = [:]
    private var inverted: [String: Set<String>] = [:]
    private var sortedTokens: [String]?
    private var isLoaded = false
    private var rebuildNeed: RebuildNeed = .none
    private let loadTask: Task<LoadOutcome, Never>
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
        self.loadTask = Task.detached(priority: .utility) {
            Self.loadSnapshot(at: indexURL)
        }
    }

    /// Indexes an entry. `auxiliaryText` (summary, notes, speaker names) is tokenized for search but never shown in snippets.
    public func index(id: String, title: String, text: String, auxiliaryText: String = "", createdAt: Date) async {
        await ensureLoaded()
        removeFromIndex(id)
        addToIndex(id: id, title: title, text: text, auxiliaryText: auxiliaryText)
        scheduleSave()
    }

    public func remove(_ id: String) async {
        await ensureLoaded()
        removeFromIndex(id)
        scheduleSave()
    }

    public func search(_ query: String) async -> [Match] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        await ensureLoaded()

        if sortedTokens == nil { sortedTokens = inverted.keys.sorted() }
        let tokens = sortedTokens ?? []
        var scores: [String: Int] = [:]
        for queryToken in Set(queryTokens) {
            // Prefix matches sort contiguously; binary-search the range instead of scanning the whole vocabulary.
            let lower = Self.firstIndex(in: tokens, atLeast: queryToken)
            let upper = Self.firstIndex(in: tokens, atLeast: queryToken + "\u{10FFFF}")
            for indexToken in tokens[lower..<upper] where indexToken.hasPrefix(queryToken) {
                for id in inverted[indexToken] ?? [] { scores[id, default: 0] += 1 }
            }
        }

        return scores
            .sorted { $0.value > $1.value }
            .compactMap { (id, score) -> Match? in
                guard let entry = entries[id] else { return nil }
                let snippet = Self.makeSnippet(text: entry.excerpt, tokens: queryTokens)
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
        guard isLoaded else { return }
        saveSnapshot()
    }

    func needsRebuild() async -> Bool {
        await ensureLoaded()
        return rebuildNeed != .none
    }

    func rebuild(entries rebuilt: [RebuildEntry]) async {
        await ensureLoaded()
        entries.removeAll()
        inverted.removeAll()
        for entry in rebuilt {
            addToIndex(id: entry.id, title: entry.title, text: entry.text, auxiliaryText: entry.auxiliaryText)
        }
        rebuildNeed = .none
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveSnapshot()
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }
        let outcome = await loadTask.value
        guard !isLoaded else { return }
        isLoaded = true
        switch outcome {
        case .loaded(let state):
            entries = state.entries
            inverted = state.inverted
            sortedTokens = nil
        case .staleDiscarded:
            rebuildNeed = .staleSnapshot
        case .missing:
            rebuildNeed = .absentSnapshot
        }
    }

    private static func loadSnapshot(at url: URL) -> LoadOutcome {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == snapshotVersion else {
            return .staleDiscarded
        }
        var entries: [String: IndexedEntry] = [:]
        var inverted: [String: Set<String>] = [:]
        entries.reserveCapacity(snapshot.entries.count)
        for (id, entry) in snapshot.entries {
            let tokens = Set(entry.tokens)
            entries[id] = IndexedEntry(title: entry.title, excerpt: entry.excerpt, tokens: tokens)
            for token in tokens {
                inverted[token, default: []].insert(id)
            }
        }
        return .loaded(LoadedState(entries: entries, inverted: inverted))
    }

    private func addToIndex(id: String, title: String, text: String, auxiliaryText: String) {
        let tokens = Set(Self.tokenize(title) + Self.tokenize(text) + Self.tokenize(auxiliaryText))
        entries[id] = IndexedEntry(
            title: title,
            excerpt: String(text.prefix(Self.excerptLength)),
            tokens: tokens
        )
        for token in tokens {
            inverted[token, default: []].insert(id)
        }
        sortedTokens = nil
    }

    private func removeFromIndex(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for token in entry.tokens {
            guard var ids = inverted[token] else { continue }
            ids.remove(id)
            if ids.isEmpty {
                inverted.removeValue(forKey: token)
            } else {
                inverted[token] = ids
            }
        }
        sortedTokens = nil
    }

    private static func firstIndex(in sorted: [String], atLeast key: String) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
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

    // Saving before the rebuild lands would leave a current-version snapshot that a later launch
    // trusts: a partial one after a stale discard, an empty one where the file was simply absent.
    private var canPersistSnapshot: Bool {
        switch rebuildNeed {
        case .none: true
        case .staleSnapshot: false
        case .absentSnapshot: !entries.isEmpty
        }
    }

    private func saveSnapshot() {
        guard canPersistSnapshot else { return }
        let snapshot = Snapshot(
            version: Self.snapshotVersion,
            entries: entries.mapValues {
                SnapshotEntry(title: $0.title, excerpt: $0.excerpt, tokens: $0.tokens.sorted())
            }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
