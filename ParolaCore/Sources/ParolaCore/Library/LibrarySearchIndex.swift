import Foundation
import NaturalLanguage
import os

public actor LibrarySearchIndex {
    public struct Highlight: Sendable, Equatable {
        public let start: Int
        public let length: Int

        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    /// Where a segment's text starts inside the joined transcript, and when it is spoken.
    public struct SegmentBoundary: Sendable, Equatable {
        public let textOffset: Int
        public let seconds: Double

        public init(textOffset: Int, seconds: Double) {
            self.textOffset = textOffset
            self.seconds = seconds
        }
    }

    public struct Match: Sendable, Equatable {
        /// The earliest place in the transcript body where any of the query's terms occurs.
        public struct FirstHit: Sendable, Equatable {
            public let seconds: Double
            /// A position in the blank-dropped segment list `LibraryStore.load` returns, not in the raw `transcript.json`.
            public let segmentIndex: Int
            public let textOffset: Int

            public init(seconds: Double, segmentIndex: Int, textOffset: Int) {
                self.seconds = seconds
                self.segmentIndex = segmentIndex
                self.textOffset = textOffset
            }
        }

        public let entryID: String
        public let score: Int
        /// How many times the query's terms occur in everything indexed for the entry, title included.
        public let matchCount: Int
        public let snippet: String
        public let highlights: [Highlight]
        /// nil when the entry matched on its title, summary or speakers alone.
        public let firstHit: FirstHit?

        public init(
            entryID: String,
            score: Int,
            matchCount: Int = 0,
            snippet: String,
            highlights: [Highlight] = [],
            firstHit: FirstHit? = nil
        ) {
            self.entryID = entryID
            self.score = score
            self.matchCount = matchCount
            self.snippet = snippet
            self.highlights = highlights
            self.firstHit = firstHit
        }
    }

    struct RebuildEntry: Sendable {
        let id: String
        let title: String
        let text: String
        let auxiliaryText: String
        let boundaries: [SegmentBoundary]
        let fingerprint: String

        init(
            id: String,
            title: String,
            text: String,
            auxiliaryText: String = "",
            boundaries: [SegmentBoundary] = [],
            fingerprint: String = ""
        ) {
            self.id = id
            self.title = title
            self.text = text
            self.auxiliaryText = auxiliaryText
            self.boundaries = boundaries
            self.fingerprint = fingerprint
        }
    }

    /// Where a query's terms first land in an entry's body, and how much of it the term covers.
    private struct Hit {
        let offset: Int
        let length: Int
    }

    /// One pass over the text answers both "how many" and "where first", so the tokens are hashed once.
    private struct Tally {
        var count = 0
        var offset = LibrarySearchIndex.noOffset

        mutating func add(at bodyOffset: Int) {
            count += 1
            if offset == LibrarySearchIndex.noOffset { offset = bodyOffset }
        }
    }

    private struct IndexedEntry: Sendable {
        let title: String
        /// The full body text, kept in memory so a snippet never needs a disk read at query time.
        let text: String
        let tokens: [String]
        let counts: [Int]
        /// Parallel to `tokens`: where the token first occurs in the body, `noOffset` for title-only tokens.
        let offsets: [Int]
        let boundaryOffsets: [Int]
        let boundaryCentiseconds: [Int]
        let fingerprint: String
    }

    private struct SnapshotEntry: Codable, Sendable {
        let id: String
        let title: String
        let text: String
        let tokens: [String]
        let counts: [Int]
        let offsets: [Int]
        let boundaryOffsets: [Int]
        let boundaryCentiseconds: [Int]
        let fingerprint: String
    }

    /// The authority on what the snapshot holds: an entry file with no row here is ignored and pruned.
    private struct Manifest: Codable, Sendable {
        let version: Int
        let entries: [String: String]
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

    private struct LoadResult: Sendable {
        let outcome: LoadOutcome
        let legacySnapshotPresent: Bool
    }

    private enum RebuildNeed: Sendable {
        case none
        case staleSnapshot
        case absentSnapshot
    }

    private struct SnapshotWrite: Sendable {
        let entries: [SnapshotEntry]
        let manifest: Manifest
        let generation: Int
        let removesLegacySnapshot: Bool
    }

    private enum WriteOutcome: Sendable {
        case written
        case superseded
        case failed(any Error)
    }

    private struct WriteResult: Sendable {
        let encoded: Int
        let outcome: WriteOutcome
    }

    // v11: one file per entry under `entries/`, listed by `manifest.json`; older snapshots are discarded and rebuilt.
    private static let snapshotVersion = 11
    private static let noOffset = -1

    private var entries: [String: IndexedEntry] = [:]
    private var inverted: [String: Set<String>] = [:]
    private var dirtyEntryIDs: Set<String> = []
    private var sortedTokens: [String]?
    private var isLoaded = false
    private var isDirty = false
    private var legacySnapshotPresent = false
    private var rebuildNeed: RebuildNeed = .none
    private var snapshotWriteFailing = false
    private let loadTask: Task<LoadResult, Never>
    private let indexDirectory: URL
    private let saveDebounce: Duration
    private let clock: any Clock<Duration>
    private var pendingSaveTask: Task<Void, Never>?
    private let writeSnapshotData: @Sendable (Data, URL) throws -> Void
    private let removeSnapshotFile: @Sendable (URL) throws -> Void
    // .default, not .utility: the quit path blocks the main thread on a plain semaphore, which donates no priority.
    private let writeQueue = DispatchQueue(label: "com.parola.search-index-write", qos: .default)
    private let latestGeneration = OSAllocatedUnfairLock(initialState: 0)
    private(set) var snapshotGeneration = 0
    private(set) var entriesEncoded = 0
    private(set) var vocabularySorts = 0

    /// `indexDirectory` holds the snapshot: a `manifest.json` and one file per entry under `entries/`.
    public init(
        indexDirectory: URL,
        saveDebounce: Duration = .milliseconds(250),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            indexDirectory: indexDirectory,
            saveDebounce: saveDebounce,
            clock: clock,
            writeSnapshotData: { data, url in try data.write(to: url, options: .atomic) },
            removeSnapshotFile: { url in try FileManager.default.removeItem(at: url) }
        )
    }

    init(
        indexDirectory: URL,
        saveDebounce: Duration,
        clock: any Clock<Duration>,
        writeSnapshotData: @escaping @Sendable (Data, URL) throws -> Void,
        removeSnapshotFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.indexDirectory = indexDirectory
        self.saveDebounce = saveDebounce
        self.clock = clock
        self.writeSnapshotData = writeSnapshotData
        self.removeSnapshotFile = removeSnapshotFile
        self.loadTask = Task.detached(priority: .utility) {
            Self.loadSnapshot(at: indexDirectory)
        }
    }

    /// Indexes an entry. `auxiliaryText` (summary, notes, speaker names) is tokenized for search but never shown in snippets.
    /// `boundaries` places each segment inside `text`, so a match can report the time of its first hit.
    /// `fingerprint` records the state of the bundle this text came from, so a later launch can tell
    /// whether the library still holds what was indexed.
    public func index(
        id: String,
        title: String,
        text: String,
        auxiliaryText: String = "",
        boundaries: [SegmentBoundary] = [],
        fingerprint: String = "",
        createdAt: Date
    ) async {
        await ensureLoaded()
        removeFromIndex(id)
        addToIndex(
            id: id, title: title, text: text, auxiliaryText: auxiliaryText,
            boundaries: boundaries, fingerprint: fingerprint
        )
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

        if sortedTokens == nil {
            sortedTokens = inverted.keys.sorted()
            vocabularySorts &+= 1
        }
        let tokens = sortedTokens ?? []
        var scores: [String: Int] = [:]
        var hits: [String: Int] = [:]
        var earliest: [String: Hit] = [:]
        for queryToken in Set(queryTokens) {
            // Prefix matches sort contiguously; binary-search the range instead of scanning the whole vocabulary.
            let lower = Self.firstIndex(in: tokens, atLeast: queryToken)
            let upper = Self.firstIndex(in: tokens, atLeast: queryToken + "\u{10FFFF}")
            for indexToken in tokens[lower..<upper] where indexToken.hasPrefix(queryToken) {
                for id in inverted[indexToken] ?? [] {
                    scores[id, default: 0] += 1
                    guard let entry = entries[id] else { continue }
                    let position = Self.position(of: indexToken, in: entry)
                    hits[id, default: 0] += Self.occurrences(at: position, in: entry)
                    if let offset = Self.bodyOffset(at: position, in: entry),
                       offset < earliest[id]?.offset ?? Int.max {
                        earliest[id] = Hit(offset: offset, length: queryToken.count)
                    }
                }
            }
        }

        var results: [Match] = []
        results.reserveCapacity(scores.count)
        for (id, score) in scores.sorted(by: { $0.value > $1.value }) {
            guard let entry = entries[id] else { continue }
            let hit = earliest[id]
            let snippet = Self.makeSnippet(text: entry.text, tokens: queryTokens, hit: hit)
            results.append(Match(
                entryID: id,
                score: score,
                matchCount: hits[id] ?? 0,
                snippet: snippet.text,
                highlights: snippet.highlights,
                firstHit: hit.flatMap { Self.firstHit(atOffset: $0.offset, in: entry) }
            ))
        }
        return results
    }

    /// The opening of every indexed entry's text, keyed by entry id, or nil when that is what `previous`
    /// already holds. Reads the text the index has in memory, so a list can show what an entry says without
    /// opening a bundle, and the comparison stays on this actor rather than on the caller's.
    public func excerpts(maxLength: Int, changedFrom previous: [String: String]) async -> [String: String]? {
        await ensureLoaded()
        var opening: [String: String] = [:]
        opening.reserveCapacity(entries.count)
        for (id, entry) in entries {
            guard let excerpt = Self.excerpt(from: entry.text, maxLength: maxLength) else { continue }
            opening[id] = excerpt
        }
        return opening == previous ? nil : opening
    }

    /// Runs of whitespace collapse to one space and the cut lands on the last word that fits,
    /// so a row never ends mid-word. nil when the entry has nothing to quote.
    public nonisolated static func excerpt(from text: String, maxLength: Int) -> String? {
        guard maxLength > 0 else { return nil }
        var collapsed = ""
        collapsed.reserveCapacity(maxLength + 1)
        var pendingSpace = false
        // Counted as it grows: `String.count` walks the whole string, and this loop would ask it per character.
        var length = 0
        for character in text {
            if character.isWhitespace {
                pendingSpace = length > 0
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                length += 1
                pendingSpace = false
            }
            collapsed.append(character)
            length += 1
            if length > maxLength { break }
        }
        guard length > 0 else { return nil }
        guard length > maxLength else { return collapsed }
        let capped = collapsed.prefix(maxLength)
        guard let lastSpace = capped.lastIndex(of: " ") else { return String(capped) + "…" }
        return String(capped[..<lastSpace]) + "…"
    }

    /// Writes any pending debounced snapshot to disk. Call before app termination.
    public func flush() async {
        let task = pendingSaveTask
        pendingSaveTask = nil
        task?.cancel()
        guard isLoaded else { return }
        await saveSnapshot()
        await drainWrites()
    }

    /// True when the snapshot is unusable, or when it was built from a different set of bundles
    /// than `fingerprints` describes — bundles added, removed or rewritten behind the app included.
    func needsRebuild(matching fingerprints: [String: String]) async -> Bool {
        await ensureLoaded()
        guard rebuildNeed == .none else { return true }
        guard entries.count == fingerprints.count else { return true }
        return entries.contains { fingerprints[$0.key] != $0.value.fingerprint }
    }

    /// Records that an entry's bundle moved without its text changing, so the next launch does not
    /// read the newer file as a reason to rebuild.
    func refreshFingerprint(_ fingerprint: String, for id: String) async {
        await ensureLoaded()
        guard let existing = entries[id], existing.fingerprint != fingerprint else { return }
        let updated = IndexedEntry(
            title: existing.title,
            text: existing.text,
            tokens: existing.tokens,
            counts: existing.counts,
            offsets: existing.offsets,
            boundaryOffsets: existing.boundaryOffsets,
            boundaryCentiseconds: existing.boundaryCentiseconds,
            fingerprint: fingerprint
        )
        entries[id] = updated
        dirtyEntryIDs.insert(id)
        isDirty = true
        scheduleSave()
    }

    func rebuild(entries rebuilt: [RebuildEntry]) async {
        await ensureLoaded()
        entries.removeAll()
        inverted.removeAll()
        dirtyEntryIDs.removeAll()
        sortedTokens = nil
        for entry in rebuilt {
            addToIndex(
                id: entry.id,
                title: entry.title,
                text: entry.text,
                auxiliaryText: entry.auxiliaryText,
                boundaries: entry.boundaries,
                fingerprint: entry.fingerprint
            )
        }
        rebuildNeed = .none
        // A library with nothing to index still needs its empty snapshot on disk, or every launch rescans.
        isDirty = true
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        await saveSnapshot()
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }
        let result = await loadTask.value
        guard !isLoaded else { return }
        isLoaded = true
        legacySnapshotPresent = result.legacySnapshotPresent
        switch result.outcome {
        case .loaded(let state):
            entries = state.entries
            inverted = state.inverted
            sortedTokens = nil
        case .staleDiscarded:
            ParolaLog.notice(.libraryIndex, "search index snapshot discarded, rebuilding")
            rebuildNeed = .staleSnapshot
        case .missing:
            rebuildNeed = .absentSnapshot
        }
    }

    private static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private static func entriesDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("entries", isDirectory: true)
    }

    private static func entryURL(_ id: String, in entriesDirectory: URL) -> URL {
        entriesDirectory.appendingPathComponent("\(id).json")
    }

    /// The single file v10 and earlier wrote, beside the directory that replaced it.
    private static func legacySnapshotURL(for directory: URL) -> URL {
        directory.appendingPathExtension("json")
    }

    private static func loadSnapshot(at directory: URL) -> LoadResult {
        let legacy = FileManager.default.fileExists(atPath: legacySnapshotURL(for: directory).path)
        guard let data = try? Data(contentsOf: manifestURL(in: directory)) else {
            return LoadResult(outcome: legacy ? .staleDiscarded : .missing, legacySnapshotPresent: legacy)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == snapshotVersion else {
            return LoadResult(outcome: .staleDiscarded, legacySnapshotPresent: legacy)
        }
        guard let decoded = decodeEntries(manifest.entries.keys.sorted(), in: entriesDirectory(in: directory)) else {
            return LoadResult(outcome: .staleDiscarded, legacySnapshotPresent: legacy)
        }
        var entries: [String: IndexedEntry] = [:]
        var inverted: [String: Set<String>] = [:]
        entries.reserveCapacity(decoded.count)
        for entry in decoded {
            entries[entry.id] = IndexedEntry(
                title: entry.title,
                text: entry.text,
                tokens: entry.tokens,
                counts: entry.counts,
                offsets: entry.offsets,
                boundaryOffsets: entry.boundaryOffsets,
                boundaryCentiseconds: entry.boundaryCentiseconds,
                fingerprint: entry.fingerprint
            )
            for token in entry.tokens {
                inverted[token, default: []].insert(entry.id)
            }
        }
        return LoadResult(
            outcome: .loaded(LoadedState(entries: entries, inverted: inverted)),
            legacySnapshotPresent: legacy
        )
    }

    /// nil when a row the manifest lists is missing or will not decode: the snapshot is then stale as a whole.
    private static func decodeEntries(_ ids: [String], in entriesDirectory: URL) -> [SnapshotEntry]? {
        guard !ids.isEmpty else { return [] }
        var decoded = [SnapshotEntry?](repeating: nil, count: ids.count)
        decoded.withUnsafeMutableBufferPointer { buffer in
            // Each iteration owns its slot, so the shared buffer never races.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: ids.count) { position in
                guard let data = try? Data(contentsOf: entryURL(ids[position], in: entriesDirectory)) else { return }
                slots[position] = try? JSONDecoder().decode(SnapshotEntry.self, from: data)
            }
        }
        var entries: [SnapshotEntry] = []
        entries.reserveCapacity(ids.count)
        for entry in decoded {
            guard let entry else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private func addToIndex(
        id: String,
        title: String,
        text: String,
        auxiliaryText: String,
        boundaries: [SegmentBoundary],
        fingerprint: String
    ) {
        install(
            Self.makeIndexedEntry(
                title: title, text: text, auxiliaryText: auxiliaryText,
                boundaries: boundaries, fingerprint: fingerprint
            ),
            for: id
        )
    }

    private static func makeIndexedEntry(
        title: String,
        text: String,
        auxiliaryText: String,
        boundaries: [SegmentBoundary],
        fingerprint: String
    ) -> IndexedEntry {
        var tallies: [String: Tally] = [:]
        enumerateTokens(in: title) { token, _ in tallies[token, default: Tally()].count += 1 }
        enumerateTokens(in: text) { token, offset in tallies[token, default: Tally()].add(at: offset) }
        enumerateTokens(in: auxiliaryText) { token, _ in tallies[token, default: Tally()].count += 1 }
        let tokens = tallies.keys.sorted()
        return IndexedEntry(
            title: title,
            text: text,
            tokens: tokens,
            counts: tokens.map { tallies[$0]?.count ?? 0 },
            offsets: tokens.map { tallies[$0]?.offset ?? noOffset },
            boundaryOffsets: boundaries.map(\.textOffset),
            boundaryCentiseconds: boundaries.map { centiseconds($0.seconds) },
            fingerprint: fingerprint
        )
    }

    private func install(_ entry: IndexedEntry, for id: String) {
        entries[id] = entry
        dirtyEntryIDs.insert(id)
        var vocabularyGrew = false
        for token in entry.tokens {
            if inverted[token] == nil { vocabularyGrew = true }
            inverted[token, default: []].insert(id)
        }
        if vocabularyGrew { sortedTokens = nil }
        isDirty = true
    }

    private func removeFromIndex(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        dirtyEntryIDs.remove(id)
        var vocabularyShrank = false
        for token in entry.tokens {
            guard var ids = inverted[token] else { continue }
            ids.remove(id)
            if ids.isEmpty {
                inverted.removeValue(forKey: token)
                vocabularyShrank = true
            } else {
                inverted[token] = ids
            }
        }
        if vocabularyShrank { sortedTokens = nil }
        isDirty = true
    }

    private static func snapshotEntry(id: String, entry: IndexedEntry) -> SnapshotEntry {
        SnapshotEntry(
            id: id,
            title: entry.title,
            text: entry.text,
            tokens: entry.tokens,
            counts: entry.counts,
            offsets: entry.offsets,
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint
        )
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

    private static func position(of token: String, in entry: IndexedEntry) -> Int? {
        let position = firstIndex(in: entry.tokens, atLeast: token)
        guard position < entry.tokens.count, entry.tokens[position] == token else { return nil }
        return position
    }

    /// An entry whose counts went missing still proves the token is in it, so the floor is 1.
    private static func occurrences(at position: Int?, in entry: IndexedEntry) -> Int {
        guard let position, position < entry.counts.count else { return 1 }
        return max(1, entry.counts[position])
    }

    /// nil for a token that only occurs in the title or the auxiliary text, which have no position.
    private static func bodyOffset(at position: Int?, in entry: IndexedEntry) -> Int? {
        guard let position, position < entry.offsets.count else { return nil }
        let offset = entry.offsets[position]
        return offset >= 0 ? offset : nil
    }

    private static func firstHit(atOffset offset: Int, in entry: IndexedEntry) -> Match.FirstHit? {
        guard !entry.boundaryOffsets.isEmpty,
              entry.boundaryCentiseconds.count == entry.boundaryOffsets.count else { return nil }
        // The offsets rise strictly, so the hit belongs to the last boundary at or before it.
        var low = 0
        var high = entry.boundaryOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if entry.boundaryOffsets[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        let index = max(0, low - 1)
        return Match.FirstHit(
            seconds: Double(entry.boundaryCentiseconds[index]) / 100,
            segmentIndex: index,
            textOffset: offset
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        enumerateTokens(in: text) { token, _ in tokens.append(token) }
        return tokens
    }

    /// Visits each token with the character offset it starts at. The offsets walk forward with the
    /// tokenizer, so the whole pass stays linear in the text's length.
    private static func enumerateTokens(in text: String, _ visit: (String, Int) -> Void) {
        guard !text.isEmpty else { return }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var cursor = text.startIndex
        var offset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range].lowercased()
            guard token.count > 1 else { return true }
            offset += text.distance(from: cursor, to: range.lowerBound)
            cursor = range.lowerBound
            visit(token, offset)
            return true
        }
    }

    /// Engine timings are Float32 widened to Double, which JSON writes as `12.399999618530273`;
    /// hundredths keep the snapshot small and still land on the right second.
    private static func centiseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(exactly: (seconds * 100).rounded()) ?? 0
    }

    /// `hit` is the offset the search already found in the inverted index, so the body is walked to
    /// the window and no further; nil means the entry matched on its title or auxiliary text alone.
    private static func makeSnippet(
        text: String,
        tokens: [String],
        hit: Hit?
    ) -> (text: String, highlights: [Highlight]) {
        guard !text.isEmpty else { return ("", []) }
        var firstHit: Range<String.Index>?
        if let hit,
           let lower = text.index(text.startIndex, offsetBy: hit.offset, limitedBy: text.endIndex),
           lower < text.endIndex {
            let upper = text.index(lower, offsetBy: hit.length, limitedBy: text.endIndex) ?? text.endIndex
            firstHit = lower..<upper
        }
        let window: Range<String.Index>
        if let firstHit {
            let lowerIdx = text.index(firstHit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let upperIdx = text.index(firstHit.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            window = lowerIdx..<upperIdx
        } else {
            window = text.startIndex..<(text.index(text.startIndex, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex)
        }
        let snippetRange = Self.alignedToWords(window, in: text, keeping: firstHit)
        let body = String(text[snippetRange])
        var highlights: [Highlight] = []
        for token in Set(tokens) {
            var cursor = body.startIndex
            while let hit = body.range(of: token, options: .caseInsensitive, range: cursor..<body.endIndex) {
                let start = body.distance(from: body.startIndex, to: hit.lowerBound)
                let length = body.distance(from: hit.lowerBound, to: hit.upperBound)
                highlights.append(Highlight(start: start, length: length))
                cursor = hit.upperBound
            }
        }
        highlights.sort { $0.start < $1.start }
        // An ellipsis says the line was cut out of a longer one; the leading one shifts every offset.
        let leading = snippetRange.lowerBound == text.startIndex ? "" : "…"
        let trailing = snippetRange.upperBound < text.endIndex ? "…" : ""
        let shift = leading.count
        let shifted = shift == 0 ? highlights : highlights.map { Highlight(start: $0.start + shift, length: $0.length) }
        return (leading + body + trailing, mergeOverlapping(shifted))
    }

    /// Pulls both cuts onto the nearest space, never past the hit itself: a snippet that starts or
    /// ends mid-word reads as a typo rather than as an excerpt.
    private static func alignedToWords(
        _ window: Range<String.Index>,
        in text: String,
        keeping hit: Range<String.Index>?
    ) -> Range<String.Index> {
        var lower = window.lowerBound
        var upper = window.upperBound
        let stopAdvancing = hit?.lowerBound ?? window.upperBound
        let stopRetreating = hit?.upperBound ?? window.lowerBound
        if lower > text.startIndex, !text[text.index(before: lower)].isWhitespace {
            while lower < stopAdvancing, !text[lower].isWhitespace { lower = text.index(after: lower) }
            while lower < stopAdvancing, text[lower].isWhitespace { lower = text.index(after: lower) }
        }
        if upper < text.endIndex, !text[upper].isWhitespace {
            while upper > stopRetreating, !text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
            while upper > stopRetreating, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        }
        return lower < upper ? lower..<upper : window
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
        guard isDirty, pendingSaveTask == nil else { return }
        let debounce = saveDebounce
        let clock = clock
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce, clock: clock)
            if Task.isCancelled { return }
            await self?.persistAfterDebounce()
        }
    }

    private func persistAfterDebounce() async {
        pendingSaveTask = nil
        await saveSnapshot()
    }

    // Saving before the rebuild lands would leave a current-version snapshot a later launch trusts: partial after a stale discard, empty where the file was absent.
    private var canPersistSnapshot: Bool {
        switch rebuildNeed {
        case .none: true
        case .staleSnapshot: false
        case .absentSnapshot: !entries.isEmpty
        }
    }

    private func saveSnapshot() async {
        guard canPersistSnapshot, isDirty else { return }
        isDirty = false
        let pending = dirtyEntryIDs
        dirtyEntryIDs.removeAll()
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        latestGeneration.withLock { $0 = generation }
        let write = SnapshotWrite(
            entries: pending.compactMap { id in entries[id].map { Self.snapshotEntry(id: id, entry: $0) } },
            manifest: Manifest(version: Self.snapshotVersion, entries: entries.mapValues(\.fingerprint)),
            generation: generation,
            removesLegacySnapshot: legacySnapshotPresent
        )
        let result = await writeSnapshot(write)
        entriesEncoded &+= result.encoded
        switch result.outcome {
        case .written:
            snapshotWriteFailing = false
            legacySnapshotPresent = false
        case .superseded:
            // The entry files landed; the newer generation writes the manifest that lists them.
            break
        case .failed(let error):
            // The retry runs on the debounce until the write lands, so only the first of a run is logged.
            if !snapshotWriteFailing {
                snapshotWriteFailing = true
                ParolaLog.error(
                    .libraryIndex, "search index snapshot write failed",
                    [.count: .int(entries.count), .error: .error(error)]
                )
            }
            dirtyEntryIDs.formUnion(pending)
            isDirty = true
            scheduleSave()
        }
    }

    private func writeSnapshot(_ write: SnapshotWrite) async -> WriteResult {
        let directory = indexDirectory
        let writeData = writeSnapshotData
        let removeFile = removeSnapshotFile
        let latestGeneration = latestGeneration
        return await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume(returning: Self.performWrite(
                    write, in: directory, writeData: writeData,
                    removeFile: removeFile, latestGeneration: latestGeneration
                ))
            }
        }
    }

    /// Entry files first, then the files of entries the manifest no longer lists, then the manifest
    /// itself: a snapshot interrupted anywhere in that order reads as stale rather than as complete.
    private static func performWrite(
        _ write: SnapshotWrite,
        in directory: URL,
        writeData: @Sendable (Data, URL) throws -> Void,
        removeFile: @Sendable (URL) throws -> Void,
        latestGeneration: OSAllocatedUnfairLock<Int>
    ) -> WriteResult {
        let entriesDirectory = entriesDirectory(in: directory)
        var encoded = 0
        do {
            try FileManager.default.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            for entry in write.entries {
                let data = try encoder.encode(entry)
                encoded += 1
                try writeData(data, entryURL(entry.id, in: entriesDirectory))
            }
            for url in unlistedEntryFiles(in: entriesDirectory, keeping: Set(write.manifest.entries.keys)) {
                try? removeFile(url)
            }
            // A snapshot that lost the race must not list an older set than the newer one it queued behind.
            guard latestGeneration.withLock({ $0 }) == write.generation else {
                return WriteResult(encoded: encoded, outcome: .superseded)
            }
            try writeData(try encoder.encode(write.manifest), manifestURL(in: directory))
            if write.removesLegacySnapshot { try? removeFile(legacySnapshotURL(for: directory)) }
            return WriteResult(encoded: encoded, outcome: .written)
        } catch {
            return WriteResult(encoded: encoded, outcome: .failed(error))
        }
    }

    private static func unlistedEntryFiles(in entriesDirectory: URL, keeping ids: Set<String>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: entriesDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.pathExtension == "json" && !ids.contains($0.deletingPathExtension().lastPathComponent)
        }
    }

    private func drainWrites() async {
        let queue = writeQueue
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
