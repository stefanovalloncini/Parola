import Foundation
import NaturalLanguage
import os

/// The snapshot directory assumes a single writer per library; two processes writing it concurrently degrade to a rebuild on the next launch, never to corruption.
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

    /// Every indexed entry's opening, and the generation that names this set of them.
    public struct Excerpts: Sendable, Equatable {
        public let generation: Int
        public let byEntry: [String: String]
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
        /// Vocabulary ids in the order of their words, which is also the order of `counts` and `offsets`.
        var tokens: [UInt32]
        let counts: [UInt32]
        /// Parallel to `tokens`: where the token first occurs in the body, `noOffset` for title-only tokens.
        let offsets: [Int32]
        let boundaryOffsets: [Int32]
        let boundaryCentiseconds: [UInt32]
        let fingerprint: String
        /// Cut from the body when the entry is indexed; nil when the body has nothing to quote.
        let excerpt: String?
        /// What the body file must hold; a file that differs is not this entry's body.
        let bodyBytes: Int
        let bodyHash: UInt64
        /// Names this installed state, so a snippet built across a suspension can tell the entry moved.
        var revision = 0
    }

    private struct SnapshotEntry: Codable, Sendable {
        let id: String
        let title: String
        let excerpt: String?
        let bodyBytes: Int
        let bodyHash: UInt64
        let tokens: [String]
        let counts: [UInt32]
        let offsets: [Int32]
        let boundaryOffsets: [Int32]
        let boundaryCentiseconds: [UInt32]
        let fingerprint: String
    }

    /// The authority on what the snapshot holds: an entry file with no row here is ignored and pruned.
    private struct Manifest: Codable, Sendable {
        let version: Int
        let entries: [String: String]
    }

    /// `entry` arrives without token ids; `words` are its tokens in order and take their ids when the entry is installed.
    private struct PreparedEntry: Sendable {
        let id: String
        let entry: IndexedEntry
        let words: [String]
        let body: String
    }

    /// A body the index holds until its file has landed; a reader never writes, so it keeps what it is given.
    private struct PendingBody: Sendable {
        let text: String
        let sequence: Int
    }

    private struct BodyWrite: Sendable {
        let id: String
        let text: String
        let sequence: Int
    }

    /// Entries by id, each held in a dense slot whose number the postings use; a removed entry's slot is reused.
    private struct EntryTable: Sendable {
        private var ordinals: [String: UInt32] = [:]
        private var slots: [IndexedEntry?] = []
        private var ids: [String] = []
        private var freeSlots: [UInt32] = []

        var count: Int { ordinals.count }
        var isEmpty: Bool { ordinals.isEmpty }
        var keys: Dictionary<String, UInt32>.Keys { ordinals.keys }
        var slotCount: Int { slots.count }

        subscript(id: String) -> IndexedEntry? {
            get { ordinals[id].flatMap { slots[Int($0)] } }
            set {
                if let newValue {
                    insert(newValue, for: id)
                } else {
                    removeValue(forKey: id)
                }
            }
        }

        func ordinal(of id: String) -> UInt32? { ordinals[id] }
        func entry(at ordinal: UInt32) -> IndexedEntry? { slots[Int(ordinal)] }
        func id(at ordinal: UInt32) -> String { ids[Int(ordinal)] }

        mutating func reserveCapacity(_ capacity: Int) {
            ordinals.reserveCapacity(capacity)
            slots.reserveCapacity(capacity)
            ids.reserveCapacity(capacity)
        }

        @discardableResult
        mutating func insert(_ entry: IndexedEntry, for id: String) -> UInt32 {
            if let existing = ordinals[id] {
                slots[Int(existing)] = entry
                return existing
            }
            let ordinal: UInt32
            if let reused = freeSlots.popLast() {
                ordinal = reused
                slots[Int(reused)] = entry
                ids[Int(reused)] = id
            } else {
                ordinal = UInt32(slots.count)
                slots.append(entry)
                ids.append(id)
            }
            ordinals[id] = ordinal
            return ordinal
        }

        @discardableResult
        mutating func removeValue(forKey id: String) -> (entry: IndexedEntry, ordinal: UInt32)? {
            guard let ordinal = ordinals.removeValue(forKey: id), let entry = slots[Int(ordinal)] else { return nil }
            slots[Int(ordinal)] = nil
            ids[Int(ordinal)] = ""
            freeSlots.append(ordinal)
            return (entry, ordinal)
        }

        mutating func removeAll() {
            ordinals.removeAll()
            slots.removeAll()
            ids.removeAll()
            freeSlots.removeAll()
        }

        var fingerprints: [String: String] {
            Dictionary(uniqueKeysWithValues: ordinals.map { ($0.key, slots[Int($0.value)]?.fingerprint ?? "") })
        }

        var excerpts: [String: String] {
            var out: [String: String] = [:]
            for (id, ordinal) in ordinals {
                if let excerpt = slots[Int(ordinal)]?.excerpt { out[id] = excerpt }
            }
            return out
        }
    }

    /// Ordinals in ascending order, so a posting list is found by bisection and merged by walking.
    enum Postings {
        static func insert(_ ordinal: UInt32, into list: inout [UInt32]) {
            guard let last = list.last, last >= ordinal else {
                list.append(ordinal)
                return
            }
            let position = lowerBound(of: ordinal, in: list)
            if position < list.count, list[position] == ordinal { return }
            list.insert(ordinal, at: position)
        }

        static func remove(_ ordinal: UInt32, from list: inout [UInt32]) {
            let position = lowerBound(of: ordinal, in: list)
            if position < list.count, list[position] == ordinal { list.remove(at: position) }
        }

        static func lowerBound(of ordinal: UInt32, in list: [UInt32]) -> Int {
            var low = 0
            var high = list.count
            while low < high {
                let mid = (low + high) / 2
                if list[mid] < ordinal { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }

    /// Every distinct token once, with the entries that hold it; a token no entry holds gives its id back.
    private struct Vocabulary: Sendable {
        private(set) var words: [String] = []
        private(set) var postings: [[UInt32]] = []
        private var ids: [String: UInt32] = [:]
        private var freeIDs: [UInt32] = []

        func id(of word: String) -> UInt32? { ids[word] }
        var liveIDs: Dictionary<String, UInt32>.Values { ids.values }

        mutating func reserveCapacity(_ capacity: Int) {
            ids.reserveCapacity(capacity)
            words.reserveCapacity(capacity)
            postings.reserveCapacity(capacity)
        }

        mutating func intern(_ word: String) -> (id: UInt32, isNew: Bool) {
            if let existing = ids[word] { return (existing, false) }
            let id: UInt32
            if let reused = freeIDs.popLast() {
                id = reused
                words[Int(reused)] = word
            } else {
                id = UInt32(words.count)
                words.append(word)
                postings.append([])
            }
            ids[word] = id
            return (id, true)
        }

        mutating func reservePostings(_ capacity: Int, for id: UInt32) {
            postings[Int(id)].reserveCapacity(capacity)
        }

        mutating func appendAscending(_ ordinal: UInt32, to id: UInt32) {
            if postings[Int(id)].last != ordinal { postings[Int(id)].append(ordinal) }
        }

        mutating func insert(_ ordinal: UInt32, into id: UInt32) {
            Postings.insert(ordinal, into: &postings[Int(id)])
        }

        /// True when the token left the vocabulary because no entry holds it any more.
        mutating func remove(_ ordinal: UInt32, from id: UInt32) -> Bool {
            Postings.remove(ordinal, from: &postings[Int(id)])
            guard postings[Int(id)].isEmpty else { return false }
            postings[Int(id)] = []
            ids.removeValue(forKey: words[Int(id)])
            words[Int(id)] = ""
            freeIDs.append(id)
            return true
        }

        mutating func removeAll() {
            words.removeAll()
            postings.removeAll()
            ids.removeAll()
            freeIDs.removeAll()
        }
    }

    private struct LoadedState: Sendable {
        let entries: EntryTable
        let vocabulary: Vocabulary
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
        let bodies: [BodyWrite]
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

    // v12: one file per entry under `entries/` and its body under `bodies/`, listed by `manifest.json`; older snapshots are discarded and rebuilt.
    private static let snapshotVersion = 12
    private static let noOffset = -1
    /// The length a library row quotes; excerpts are cut once, at index time, to this.
    public static let excerptLength = 240

    private var entries = EntryTable()
    private var vocabulary = Vocabulary()
    private var excerptsByEntry: [String: String] = [:]
    private var excerptsGeneration = 0
    private var dirtyEntryIDs: Set<String> = []
    private var dirtyBodyIDs: Set<String> = []
    private var pendingBodies: [String: PendingBody] = [:]
    private var bodySequence = 0
    private var revisionCounter = 0
    private var indexTickets: [String: Int] = [:]
    private var inFlightIndexes: [Int: Task<Void, Never>] = [:]
    private var pendingFingerprints: [String: String] = [:]
    private var unsoundBodies: Set<String> = []
    private var ticketCounter = 0
    private var sortedTokenIDs: [UInt32]?
    private var isLoaded = false
    private var isDirty = false
    private var legacySnapshotPresent = false
    private var rebuildNeed: RebuildNeed = .none
    private var snapshotWriteFailing = false
    private var failedWriteStreak = 0
    private static let longestRetryDelay = Duration.seconds(30)
    private static let snippetBatch = 64
    /// Started by the first call that needs the index, so a process that never searches never decodes the snapshot.
    private var loadTask: Task<LoadResult, Never>?
    /// The snapshot manifest's date when this index last read it, and the ids that manifest listed.
    private var snapshotStamp: Date?
    private var snapshotListed: Set<String> = []
    private let indexDirectory: URL
    /// False for a reader: the index lives in memory and the snapshot on disk stays the owner's.
    private let persists: Bool
    private let saveDebounce: Duration
    private let clock: any Clock<Duration>
    private var pendingSaveTask: Task<Void, Never>?
    private let writeSnapshotData: @Sendable (Data, URL) throws -> Void
    private let removeSnapshotFile: @Sendable (URL) throws -> Void
    /// A test seam: runs on the thread that tokenizes one entry, ahead of the work.
    private let beforeTokenizing: (@Sendable () -> Void)?
    // .default, not .utility: the quit path blocks the main thread on a plain semaphore, which donates no priority.
    private let writeQueue = DispatchQueue(label: "com.parola.search-index-write", qos: .default)
    private let latestGeneration = OSAllocatedUnfairLock(initialState: 0)
    private(set) var snapshotGeneration = 0
    private(set) var entriesEncoded = 0
    private(set) var vocabularySorts = 0
    private(set) var entriesDecoded = 0
    private(set) var flushesAwaitingIndexing = 0

    /// `indexDirectory` holds the snapshot: a `manifest.json`, one file per entry under `entries/` and its body under `bodies/`.
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

    /// An index that answers from memory and never writes the snapshot, for a process that reads a library another one owns.
    init(readingSnapshotIn indexDirectory: URL) {
        self.init(
            indexDirectory: indexDirectory,
            saveDebounce: .milliseconds(250),
            clock: ContinuousClock(),
            writeSnapshotData: { data, url in try data.write(to: url, options: .atomic) },
            persists: false
        )
    }

    init(
        indexDirectory: URL,
        saveDebounce: Duration,
        clock: any Clock<Duration>,
        writeSnapshotData: @escaping @Sendable (Data, URL) throws -> Void,
        removeSnapshotFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        persists: Bool = true,
        beforeTokenizing: (@Sendable () -> Void)? = nil
    ) {
        self.beforeTokenizing = beforeTokenizing
        self.indexDirectory = indexDirectory
        self.saveDebounce = saveDebounce
        self.clock = clock
        self.writeSnapshotData = writeSnapshotData
        self.removeSnapshotFile = removeSnapshotFile
        self.persists = persists
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
        ticketCounter &+= 1
        let ticket = ticketCounter
        indexTickets[id] = ticket
        pendingFingerprints[id] = nil
        let request = RebuildEntry(
            id: id, title: title, text: text, auxiliaryText: auxiliaryText,
            boundaries: boundaries, fingerprint: fingerprint
        )
        let work = Task { await self.finishIndexing(request, ticket: ticket) }
        inFlightIndexes[ticket] = work
        await work.value
    }

    /// Tokenizes off the actor and installs the result unless a later call for the same entry, or a removal, overtook this one.
    private func finishIndexing(_ request: RebuildEntry, ticket: Int) async {
        defer { inFlightIndexes[ticket] = nil }
        let id = request.id
        guard indexTickets[id] == ticket else { return }
        let prepared = await Self.tokenizeOffActor([request], before: beforeTokenizing)
        guard indexTickets[id] == ticket, let prepared = prepared.first else { return }
        indexTickets[id] = nil
        let unchanged = !unsoundBodies.contains(id)
            && entries[id].map { $0.bodyBytes == prepared.entry.bodyBytes && $0.bodyHash == prepared.entry.bodyHash } == true
        removeFromIndex(id)
        install(prepared.entry, words: prepared.words, body: unchanged ? nil : prepared.body, for: id)
        if let fingerprint = pendingFingerprints.removeValue(forKey: id) { applyFingerprint(fingerprint, for: id) }
        scheduleSave()
    }

    /// Swaps one piece of an entry's auxiliary text for another without tokenizing the rest again.
    /// False when the entry is not indexed or is being indexed, so the caller can index it whole instead.
    public func replaceAuxiliaryText(_ old: String, with new: String, for id: String) async -> Bool {
        await ensureLoaded()
        guard indexTickets[id] == nil, let entry = entries[id] else { return false }
        var tallies: [String: Tally] = [:]
        for (position, tokenID) in entry.tokens.enumerated() {
            tallies[vocabulary.words[Int(tokenID)]] = Tally(
                count: position < entry.counts.count ? Int(entry.counts[position]) : 1,
                offset: position < entry.offsets.count ? Int(entry.offsets[position]) : Self.noOffset
            )
        }
        Self.enumerateTokens(in: old) { token, _ in tallies[token]?.count -= 1 }
        Self.enumerateTokens(in: new) { token, _ in tallies[token, default: Tally()].count += 1 }
        // A token the body holds keeps its place however the card changes; one only the old card held goes.
        tallies = tallies.filter { $0.value.count > 0 || $0.value.offset != Self.noOffset }
        let tokens = tallies.keys.sorted()
        let replaced = IndexedEntry(
            title: entry.title,
            tokens: [],
            counts: tokens.map { UInt32(clamping: max(1, tallies[$0]?.count ?? 1)) },
            offsets: tokens.map { Int32(clamping: tallies[$0]?.offset ?? Self.noOffset) },
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint,
            excerpt: entry.excerpt,
            bodyBytes: entry.bodyBytes,
            bodyHash: entry.bodyHash
        )
        removeFromIndex(id)
        install(replaced, words: tokens, body: nil, for: id)
        scheduleSave()
        return true
    }

    public func remove(_ id: String) async {
        await ensureLoaded()
        indexTickets[id] = nil
        pendingFingerprints[id] = nil
        removeFromIndex(id)
        discardBody(of: id)
        if excerptsByEntry.removeValue(forKey: id) != nil { excerptsGeneration &+= 1 }
        scheduleSave()
    }

    /// With `snippets` off every match comes back with an empty snippet, for a caller that fills only
    /// the ones it shows through `withSnippets(_:query:)`: each snippet walks the body to its hit.
    public func search(_ query: String, snippets: Bool = true) async -> [Match] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        await ensureLoaded()

        if sortedTokenIDs == nil {
            let words = vocabulary.words
            sortedTokenIDs = vocabulary.liveIDs.sorted { words[Int($0)] < words[Int($1)] }
            vocabularySorts &+= 1
        }
        let tokens = sortedTokenIDs ?? []
        let words = vocabulary.words
        let slotCount = entries.slotCount
        var scores = [Int](repeating: 0, count: slotCount)
        var hits = [Int](repeating: 0, count: slotCount)
        var earliest = [Int](repeating: Int.max, count: slotCount)
        var touched: [UInt32] = []
        for queryToken in Set(queryTokens) {
            // Prefix matches sort contiguously; binary-search the range instead of scanning the whole vocabulary.
            let lower = Self.firstIndex(in: tokens, atLeast: queryToken, words: words)
            let upper = Self.firstIndex(in: tokens, atLeast: queryToken + "\u{10FFFF}", words: words)
            for tokenID in tokens[lower..<upper] where words[Int(tokenID)].hasPrefix(queryToken) {
                for ordinal in vocabulary.postings[Int(tokenID)] {
                    let slot = Int(ordinal)
                    if scores[slot] == 0 { touched.append(ordinal) }
                    scores[slot] += 1
                    guard let entry = entries.entry(at: ordinal) else { continue }
                    let position = Self.position(of: tokenID, in: entry, words: words)
                    hits[slot] += Self.occurrences(at: position, in: entry)
                    if let offset = Self.bodyOffset(at: position, in: entry), offset < earliest[slot] {
                        earliest[slot] = offset
                    }
                }
            }
        }

        touched.sort { scores[Int($0)] != scores[Int($1)] ? scores[Int($0)] > scores[Int($1)] : $0 < $1 }
        var results: [Match] = []
        results.reserveCapacity(touched.count)
        for ordinal in touched {
            let slot = Int(ordinal)
            guard let entry = entries.entry(at: ordinal) else { continue }
            results.append(Match(
                entryID: entries.id(at: ordinal),
                score: scores[slot],
                matchCount: hits[slot],
                snippet: "",
                highlights: [],
                firstHit: earliest[slot] == Int.max ? nil : Self.firstHit(atOffset: earliest[slot], in: entry)
            ))
        }
        return snippets ? await withSnippets(results, query: query) : results
    }

    /// The matches with their snippets built, as `search` builds them; one whose entry has left the index comes back as it was.
    public func withSnippets(_ matches: [Match], query: String) async -> [Match] {
        let queryTokens = Set(Self.tokenize(query))
        guard !queryTokens.isEmpty, !matches.isEmpty else { return matches }
        await ensureLoaded()
        var filled: [Match] = []
        filled.reserveCapacity(matches.count)
        for start in stride(from: 0, to: matches.count, by: Self.snippetBatch) {
            let batch = matches[start..<min(start + Self.snippetBatch, matches.count)]
            filled += await snippets(for: batch, queryTokens: queryTokens)
        }
        return filled
    }

    private func snippets(for batch: ArraySlice<Match>, queryTokens: Set<String>) async -> [Match] {
        var captured: [String: IndexedEntry] = [:]
        for match in batch {
            if let entry = entries[match.entryID] { captured[match.entryID] = entry }
        }
        let bodies = await bodies(for: captured)
        let words = vocabulary.words
        return batch.map { match in
            guard let entry = captured[match.entryID], entries[match.entryID]?.revision == entry.revision,
                  let body = bodies[match.entryID] else { return match }
            let snippet = Self.snippet(for: queryTokens, body: body, in: entry, words: words)
            return Match(
                entryID: match.entryID,
                score: match.score,
                matchCount: match.matchCount,
                snippet: snippet.text,
                highlights: snippet.highlights,
                firstHit: match.firstHit
            )
        }
    }

    /// The opening of every indexed entry's text, keyed by entry id, or nil when `generation` already names it.
    /// Excerpts are cut as entries are indexed, so a caller that is up to date pays nothing here.
    public func excerpts(after generation: Int) async -> Excerpts? {
        await ensureLoaded()
        guard generation != excerptsGeneration else { return nil }
        return Excerpts(generation: excerptsGeneration, byEntry: excerptsByEntry)
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
        while let indexing = inFlightIndexes.values.first {
            flushesAwaitingIndexing += 1
            await indexing.value
            flushesAwaitingIndexing -= 1
        }
        guard persists, isLoaded else { return }
        await saveSnapshot()
        await drainWrites()
    }

    /// How far the index is from the bundles `fingerprints` describes.
    struct Staleness: Sendable, Equatable {
        /// The snapshot was absent or unusable, so every entry has to be read again.
        var needsRebuild = false
        /// Bundles that are new or have moved since they were indexed.
        var changed: Set<String> = []
        /// Entries whose bundle has left the library.
        var removed: Set<String> = []

        var isCurrent: Bool { !needsRebuild && changed.isEmpty && removed.isEmpty }
    }

    /// Bundles added, removed or rewritten behind this index show up here, so only they are read again.
    func staleness(matching fingerprints: [String: String]) async -> Staleness {
        await ensureLoaded()
        guard rebuildNeed == .none else { return Staleness(needsRebuild: true) }
        return Staleness(
            changed: Set(fingerprints.lazy.filter { self.entries[$0.key]?.fingerprint != $0.value }.map(\.key)),
            removed: Set(entries.keys.lazy.filter { fingerprints[$0] == nil })
        )
    }

    /// True when the snapshot is unusable, or when it was built from a different set of bundles
    /// than `fingerprints` describes — bundles added, removed or rewritten behind the app included.
    func needsRebuild(matching fingerprints: [String: String]) async -> Bool {
        await !staleness(matching: fingerprints).isCurrent
    }

    /// Records that an entry's bundle moved without its text changing, so the next launch does not
    /// read the newer file as a reason to rebuild.
    func refreshFingerprint(_ fingerprint: String, for id: String) async {
        await ensureLoaded()
        if indexTickets[id] != nil {
            pendingFingerprints[id] = fingerprint
            return
        }
        applyFingerprint(fingerprint, for: id)
    }

    private func applyFingerprint(_ fingerprint: String, for id: String) {
        guard let existing = entries[id], existing.fingerprint != fingerprint, !unsoundBodies.contains(id) else { return }
        entries[id] = IndexedEntry(
            title: existing.title,
            tokens: existing.tokens,
            counts: existing.counts,
            offsets: existing.offsets,
            boundaryOffsets: existing.boundaryOffsets,
            boundaryCentiseconds: existing.boundaryCentiseconds,
            fingerprint: fingerprint,
            excerpt: existing.excerpt,
            bodyBytes: existing.bodyBytes,
            bodyHash: existing.bodyHash,
            revision: existing.revision
        )
        dirtyEntryIDs.insert(id)
        isDirty = true
        scheduleSave()
    }

    /// Callers must hold off `index` and `remove` across this call: it suspends while it tokenizes, and the install that follows replaces every entry.
    func rebuild(entries rebuilt: [RebuildEntry]) async {
        await ensureLoaded()
        // Tokenized before the old index is dropped, so a search during the pass still answers from it.
        let prepared = await Self.tokenizeOffActor(rebuilt)
        entries.removeAll()
        vocabulary.removeAll()
        dirtyEntryIDs.removeAll()
        dirtyBodyIDs.removeAll()
        pendingBodies.removeAll()
        indexTickets.removeAll()
        pendingFingerprints.removeAll()
        sortedTokenIDs = nil
        for entry in prepared {
            install(entry.entry, words: entry.words, body: entry.body, for: entry.id)
        }
        let kept = Set(prepared.map(\.id))
        let dropped = excerptsByEntry.keys.filter { !kept.contains($0) }
        if !dropped.isEmpty {
            for id in dropped { excerptsByEntry.removeValue(forKey: id) }
            excerptsGeneration &+= 1
        }
        rebuildNeed = .none
        // A library with nothing to index still needs its empty snapshot on disk, or every launch rescans.
        isDirty = true
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        await saveSnapshot()
    }

    /// Replaces the entries a scan found changed and drops the gone ones; callers hold off `index` and `remove`, as for `rebuild`.
    func reconcile(entries changed: [RebuildEntry], removing removed: Set<String>) async {
        await ensureLoaded()
        let prepared = await Self.tokenizeOffActor(changed)
        for id in removed {
            removeFromIndex(id)
            discardBody(of: id)
            if excerptsByEntry.removeValue(forKey: id) != nil { excerptsGeneration &+= 1 }
        }
        for entry in prepared {
            removeFromIndex(entry.id)
            install(entry.entry, words: entry.words, body: entry.body, for: entry.id)
        }
        scheduleSave()
    }

    /// Decodes only the owner's entry files written since this index last read the snapshot; false means load it whole.
    func refreshFromSnapshot() async -> Bool {
        guard isLoaded else { return loadTask == nil }
        let directory = indexDirectory
        let stamp = Self.modificationDate(of: Self.manifestURL(in: directory))
        let since = snapshotStamp
        let known = Set(entries.keys)
        let read = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.snapshotChanges(in: directory, since: since, known: known))
            }
        }
        guard let changes = read else { return false }
        for id in snapshotListed.subtracting(changes.listed) {
            removeFromIndex(id)
            discardBody(of: id)
            if excerptsByEntry.removeValue(forKey: id) != nil { excerptsGeneration &+= 1 }
        }
        for entry in changes.decoded {
            removeFromIndex(entry.id)
            discardBody(of: entry.id)
            install(entry.entry, words: entry.words, body: nil, for: entry.id)
        }
        entriesDecoded &+= changes.decoded.count
        snapshotStamp = stamp
        snapshotListed = changes.listed
        return true
    }

    /// An entry whose body is missing or is not the one it was indexed with is left out, and the owner marks it stale.
    private func bodies(for captured: [String: IndexedEntry]) async -> [String: String] {
        var found: [String: String] = [:]
        var onDisk: [String: IndexedEntry] = [:]
        for (id, entry) in captured {
            if let pending = pendingBodies[id] { found[id] = pending.text } else { onDisk[id] = entry }
        }
        guard !onDisk.isEmpty else { return found }
        let directory = Self.bodiesDirectory(in: indexDirectory)
        let wanted = onDisk
        let read = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.readBodies(wanted, in: directory))
            }
        }
        if persists {
            for id in read.unsound where !unsoundBodies.contains(id) && entries[id]?.revision == captured[id]?.revision {
                markUnsound(id)
            }
        }
        return found.merging(read.found) { memory, _ in memory }
    }

    private func markUnsound(_ id: String) {
        guard let existing = entries[id] else { return }
        unsoundBodies.insert(id)
        entries[id] = IndexedEntry(
            title: existing.title,
            tokens: existing.tokens,
            counts: existing.counts,
            offsets: existing.offsets,
            boundaryOffsets: existing.boundaryOffsets,
            boundaryCentiseconds: existing.boundaryCentiseconds,
            fingerprint: "",
            excerpt: existing.excerpt,
            bodyBytes: existing.bodyBytes,
            bodyHash: existing.bodyHash,
            revision: existing.revision
        )
        dirtyEntryIDs.insert(id)
        isDirty = true
        scheduleSave()
    }

    private static func readBodies(
        _ expected: [String: IndexedEntry], in directory: URL
    ) -> (found: [String: String], unsound: [String]) {
        let ids = Array(expected.keys)
        var texts = [String?](repeating: nil, count: ids.count)
        texts.withUnsafeMutableBufferPointer { buffer in
            // Each iteration owns its slot, so the shared buffer never races.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: ids.count) { position in
                guard let entry = expected[ids[position]] else { return }
                let data = (try? Data(contentsOf: bodyURL(ids[position], in: directory))) ?? Data()
                guard digest(of: data) == (entry.bodyBytes, entry.bodyHash) else { return }
                slots[position] = String(decoding: data, as: UTF8.self)
            }
        }
        var found: [String: String] = [:]
        var unsound: [String] = []
        for (id, text) in zip(ids, texts) {
            if let text { found[id] = text } else { unsound.append(id) }
        }
        return (found, unsound)
    }

    /// FNV-1a over the UTF-8 bytes: cheap enough to run on every body read, enough to tell a body from a different one.
    private static func digest(of data: Data) -> (Int, UInt64) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return (data.count, hash)
    }

    private static func digest(of text: String) -> (Int, UInt64) {
        var hash: UInt64 = 0xcbf29ce484222325
        var count = 0
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            count += 1
        }
        return (count, hash)
    }

    private func discardBody(of id: String) {
        pendingBodies.removeValue(forKey: id)
        dirtyBodyIDs.remove(id)
        unsoundBodies.remove(id)
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }
        let task: Task<LoadResult, Never>
        if let loadTask {
            task = loadTask
        } else {
            let directory = indexDirectory
            snapshotStamp = Self.modificationDate(of: Self.manifestURL(in: directory))
            task = Task.detached(priority: .utility) {
                await Self.loadSnapshotOffPool(at: directory)
            }
            loadTask = task
        }
        let result = await task.value
        guard !isLoaded else { return }
        isLoaded = true
        // The task would otherwise hold the loaded state for the index's lifetime, beside the copy edits make.
        loadTask = nil
        legacySnapshotPresent = result.legacySnapshotPresent
        switch result.outcome {
        case .loaded(let state):
            entries = state.entries
            vocabulary = state.vocabulary
            snapshotListed = Set(state.entries.keys)
            entriesDecoded &+= state.entries.count
            sortedTokenIDs = nil
            excerptsByEntry = state.entries.excerpts
            if !excerptsByEntry.isEmpty { excerptsGeneration &+= 1 }
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

    private static func bodiesDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("bodies", isDirectory: true)
    }

    private static func bodyURL(_ id: String, in bodiesDirectory: URL) -> URL {
        bodiesDirectory.appendingPathComponent("\(id).txt")
    }

    /// The single file v10 and earlier wrote, beside the directory that replaced it.
    private static func legacySnapshotURL(for directory: URL) -> URL {
        directory.appendingPathExtension("json")
    }

    /// The reads and the parallel decode would otherwise hold a cooperative-pool thread for the whole load.
    private static func loadSnapshotOffPool(at directory: URL) async -> LoadResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: loadSnapshot(at: directory))
            }
        }
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
        let ids = manifest.entries.keys.sorted()
        guard let decoded = decodeEntries(ids, in: entriesDirectory(in: directory)) else {
            return LoadResult(outcome: .staleDiscarded, legacySnapshotPresent: legacy)
        }
        var entries = EntryTable()
        entries.reserveCapacity(decoded.count)
        var vocabulary = Vocabulary()
        var holders: [Int] = []
        var tokenIDs: [[UInt32]] = []
        tokenIDs.reserveCapacity(decoded.count)
        for (id, entry) in zip(ids, decoded) {
            // A file left behind by a write that failed under a manifest a later save wrote: stale, not current.
            guard entry.id == id, manifest.entries[id] == entry.fingerprint else {
                return LoadResult(outcome: .staleDiscarded, legacySnapshotPresent: legacy)
            }
            let interned = entry.tokens.map { vocabulary.intern($0).id }
            if holders.count < vocabulary.words.count {
                holders.append(contentsOf: repeatElement(0, count: vocabulary.words.count - holders.count))
            }
            for tokenID in interned { holders[Int(tokenID)] += 1 }
            tokenIDs.append(interned)
        }
        for (tokenID, count) in holders.enumerated() { vocabulary.reservePostings(count, for: UInt32(tokenID)) }
        for (position, entry) in zip(ids, decoded).enumerated() {
            let ordinal = entries.insert(indexedEntry(from: entry.1, tokens: tokenIDs[position]), for: entry.0)
            for tokenID in tokenIDs[position] { vocabulary.appendAscending(ordinal, to: tokenID) }
        }
        return LoadResult(
            outcome: .loaded(LoadedState(entries: entries, vocabulary: vocabulary)),
            legacySnapshotPresent: legacy
        )
    }

    private static func indexedEntry(from entry: SnapshotEntry, tokens: [UInt32] = []) -> IndexedEntry {
        IndexedEntry(
            title: entry.title,
            tokens: tokens,
            counts: entry.counts,
            offsets: entry.offsets,
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint,
            excerpt: entry.excerpt,
            bodyBytes: entry.bodyBytes,
            bodyHash: entry.bodyHash
        )
    }

    private struct SnapshotChanges: Sendable {
        let listed: Set<String>
        let decoded: [PreparedEntry]
    }

    /// The owner's current manifest, with the entries it lists that are new to `known` or were written after `since`.
    private static func snapshotChanges(in directory: URL, since: Date?, known: Set<String>) -> SnapshotChanges? {
        guard let data = try? Data(contentsOf: manifestURL(in: directory)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == snapshotVersion else { return nil }
        let entriesDirectory = entriesDirectory(in: directory)
        let ids = manifest.entries.keys.filter { id in
            guard let since, known.contains(id) else { return true }
            // A tie decodes again: an entry written in the same instant as the manifest last read may be newer than it.
            return modificationDate(of: entryURL(id, in: entriesDirectory)).map { $0 >= since } ?? true
        }.sorted()
        guard let decoded = decodeEntries(ids, in: entriesDirectory) else { return nil }
        var prepared: [PreparedEntry] = []
        for (id, entry) in zip(ids, decoded) {
            guard entry.id == id, manifest.entries[id] == entry.fingerprint else { return nil }
            prepared.append(PreparedEntry(id: id, entry: indexedEntry(from: entry), words: entry.tokens, body: ""))
        }
        return SnapshotChanges(listed: Set(manifest.entries.keys), decoded: prepared)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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

    private static func tokenizeOffActor(_ rebuilt: [RebuildEntry], before: (@Sendable () -> Void)? = nil) async -> [PreparedEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                before?()
                continuation.resume(returning: tokenizeInParallel(rebuilt))
            }
        }
    }

    /// One `NLTokenizer` per entry, never shared: the tokenizer is not thread-safe.
    private static func tokenizeInParallel(_ rebuilt: [RebuildEntry]) -> [PreparedEntry] {
        guard !rebuilt.isEmpty else { return [] }
        var prepared = [PreparedEntry?](repeating: nil, count: rebuilt.count)
        prepared.withUnsafeMutableBufferPointer { buffer in
            // Each iteration owns its slot, so the shared buffer never races.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: rebuilt.count) { position in
                let source = rebuilt[position]
                let tokenized = makeIndexedEntry(
                    title: source.title,
                    text: source.text,
                    auxiliaryText: source.auxiliaryText,
                    boundaries: source.boundaries,
                    fingerprint: source.fingerprint
                )
                slots[position] = PreparedEntry(id: source.id, entry: tokenized.entry, words: tokenized.words, body: source.text)
            }
        }
        return prepared.compactMap { $0 }
    }

    private static func makeIndexedEntry(
        title: String,
        text: String,
        auxiliaryText: String,
        boundaries: [SegmentBoundary],
        fingerprint: String
    ) -> (entry: IndexedEntry, words: [String]) {
        var tallies: [String: Tally] = [:]
        enumerateTokens(in: title) { token, _ in tallies[token, default: Tally()].count += 1 }
        enumerateTokens(in: text) { token, offset in tallies[token, default: Tally()].add(at: offset) }
        enumerateTokens(in: auxiliaryText) { token, _ in tallies[token, default: Tally()].count += 1 }
        let tokens = tallies.keys.sorted()
        let bodyDigest = digest(of: text)
        let entry = IndexedEntry(
            title: title,
            tokens: [],
            counts: tokens.map { UInt32(clamping: tallies[$0]?.count ?? 0) },
            offsets: tokens.map { Int32(clamping: tallies[$0]?.offset ?? noOffset) },
            boundaryOffsets: boundaries.map { Int32(clamping: $0.textOffset) },
            boundaryCentiseconds: boundaries.map { centiseconds($0.seconds) },
            fingerprint: fingerprint,
            excerpt: excerpt(from: text, maxLength: excerptLength),
            bodyBytes: bodyDigest.0,
            bodyHash: bodyDigest.1
        )
        return (entry, tokens)
    }

    /// A nil `body` leaves the one already held or on disk as it is.
    private func install(_ entry: IndexedEntry, words: [String], body: String?, for id: String) {
        var entry = entry
        var vocabularyGrew = false
        entry.tokens = words.map { word in
            let interned = vocabulary.intern(word)
            if interned.isNew { vocabularyGrew = true }
            return interned.id
        }
        revisionCounter &+= 1
        entry.revision = revisionCounter
        let ordinal = entries.insert(entry, for: id)
        if let body {
            unsoundBodies.remove(id)
            bodySequence &+= 1
            pendingBodies[id] = PendingBody(text: body, sequence: bodySequence)
            dirtyBodyIDs.insert(id)
        }
        if excerptsByEntry[id] != entry.excerpt {
            excerptsByEntry[id] = entry.excerpt
            excerptsGeneration &+= 1
        }
        dirtyEntryIDs.insert(id)
        for tokenID in entry.tokens { vocabulary.insert(ordinal, into: tokenID) }
        if vocabularyGrew { sortedTokenIDs = nil }
        isDirty = true
    }

    private func removeFromIndex(_ id: String) {
        guard let (entry, ordinal) = entries.removeValue(forKey: id) else { return }
        dirtyEntryIDs.remove(id)
        var vocabularyShrank = false
        for tokenID in entry.tokens where vocabulary.remove(ordinal, from: tokenID) { vocabularyShrank = true }
        if vocabularyShrank { sortedTokenIDs = nil }
        isDirty = true
    }

    private static func snapshotEntry(id: String, entry: IndexedEntry, words: [String]) -> SnapshotEntry {
        SnapshotEntry(
            id: id,
            title: entry.title,
            excerpt: entry.excerpt,
            bodyBytes: entry.bodyBytes,
            bodyHash: entry.bodyHash,
            tokens: entry.tokens.map { words[Int($0)] },
            counts: entry.counts,
            offsets: entry.offsets,
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint
        )
    }

    private static func firstIndex(in sorted: [UInt32], atLeast key: String, words: [String]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if words[Int(sorted[mid])] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func position(of tokenID: UInt32, in entry: IndexedEntry, words: [String]) -> Int? {
        let position = firstIndex(in: entry.tokens, atLeast: words[Int(tokenID)], words: words)
        guard position < entry.tokens.count, entry.tokens[position] == tokenID else { return nil }
        return position
    }

    /// An entry whose counts went missing still proves the token is in it, so the floor is 1.
    private static func occurrences(at position: Int?, in entry: IndexedEntry) -> Int {
        guard let position, position < entry.counts.count else { return 1 }
        return max(1, Int(entry.counts[position]))
    }

    /// nil for a token that only occurs in the title or the auxiliary text, which have no position.
    private static func bodyOffset(at position: Int?, in entry: IndexedEntry) -> Int? {
        guard let position, position < entry.offsets.count else { return nil }
        let offset = entry.offsets[position]
        return offset >= 0 ? Int(offset) : nil
    }

    private static func firstHit(atOffset offset: Int, in entry: IndexedEntry) -> Match.FirstHit? {
        guard !entry.boundaryOffsets.isEmpty,
              entry.boundaryCentiseconds.count == entry.boundaryOffsets.count else { return nil }
        // The offsets rise strictly, so the hit belongs to the last boundary at or before it.
        var low = 0
        var high = entry.boundaryOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if Int(entry.boundaryOffsets[mid]) <= offset { low = mid + 1 } else { high = mid }
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
    private static func centiseconds(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(exactly: (seconds * 100).rounded()) ?? 0
    }

    private static func snippet(
        for queryTokens: Set<String>, body: String, in entry: IndexedEntry, words: [String]
    ) -> (text: String, highlights: [Highlight]) {
        makeSnippet(text: body, tokens: queryTokens, hit: earliestHit(of: queryTokens, in: entry, words: words))
    }

    /// Where the body first holds a word some query token starts; at a tie the longer token wins, never set order.
    private static func earliestHit(of queryTokens: Set<String>, in entry: IndexedEntry, words: [String]) -> Hit? {
        var best: Hit?
        for queryToken in queryTokens {
            // The same range `search` reads: sorted by scalars, then held to the prefix by characters.
            let lower = firstIndex(in: entry.tokens, atLeast: queryToken, words: words)
            let upper = firstIndex(in: entry.tokens, atLeast: queryToken + "\u{10FFFF}", words: words)
            for position in lower..<upper where words[Int(entry.tokens[position])].hasPrefix(queryToken) {
                guard let offset = bodyOffset(at: position, in: entry) else { continue }
                if offset < best?.offset ?? Int.max
                    || (offset == best?.offset && queryToken.count > best?.length ?? 0) {
                    best = Hit(offset: offset, length: queryToken.count)
                }
            }
        }
        return best
    }

    /// `hit` comes from the index, so the body is walked to the window and never searched.
    private static func makeSnippet(
        text: String,
        tokens: Set<String>,
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
        for token in tokens {
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
        guard persists, isDirty, pendingSaveTask == nil else { return }
        let debounce = retryDelay
        let clock = clock
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce, clock: clock)
            if Task.isCancelled { return }
            await self?.persistAfterDebounce()
        }
    }

    /// The debounce, doubled for each write in a row that failed, so a folder that cannot be written is not retried at the debounce's rate.
    private var retryDelay: Duration {
        guard failedWriteStreak > 0 else { return saveDebounce }
        return max(saveDebounce, min(Self.longestRetryDelay, saveDebounce * (1 << min(failedWriteStreak - 1, 20))))
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
        guard persists, canPersistSnapshot, isDirty else { return }
        isDirty = false
        let pending = dirtyEntryIDs
        let pendingBodyIDs = dirtyBodyIDs
        dirtyEntryIDs.removeAll()
        dirtyBodyIDs.removeAll()
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        latestGeneration.withLock { $0 = generation }
        let write = SnapshotWrite(
            entries: pending.compactMap { id in entries[id].map { Self.snapshotEntry(id: id, entry: $0, words: vocabulary.words) } },
            bodies: pendingBodyIDs.compactMap { id in
                pendingBodies[id].map { BodyWrite(id: id, text: $0.text, sequence: $0.sequence) }
            },
            manifest: Manifest(version: Self.snapshotVersion, entries: entries.fingerprints),
            generation: generation,
            removesLegacySnapshot: legacySnapshotPresent
        )
        let result = await writeSnapshot(write)
        entriesEncoded &+= result.encoded
        switch result.outcome {
        case .written:
            snapshotWriteFailing = false
            failedWriteStreak = 0
            legacySnapshotPresent = false
            releaseBodies(write.bodies)
        case .superseded:
            // The entry files landed; the newer generation writes the manifest that lists them.
            releaseBodies(write.bodies)
        case .failed(let error):
            // The retries back off until a write lands, so only the first of a run is logged.
            failedWriteStreak += 1
            if !snapshotWriteFailing {
                snapshotWriteFailing = true
                ParolaLog.error(
                    .libraryIndex, "search index snapshot write failed",
                    [.count: .int(entries.count), .error: .error(error)]
                )
            }
            dirtyEntryIDs.formUnion(pending)
            dirtyBodyIDs.formUnion(pendingBodyIDs.filter { pendingBodies[$0] != nil })
            isDirty = true
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            scheduleSave()
        }
    }

    private func releaseBodies(_ written: [BodyWrite]) {
        guard persists else { return }
        for body in written where pendingBodies[body.id]?.sequence == body.sequence {
            pendingBodies.removeValue(forKey: body.id)
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

    /// Bodies land first, then entry files, then the manifest, so a write interrupted anywhere reads as stale, never as complete; a body that outlives its entry file fails the entry's digest and is not quoted.
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
            let bodiesDirectory = bodiesDirectory(in: directory)
            try FileManager.default.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
            for body in write.bodies {
                try writeData(Data(body.text.utf8), bodyURL(body.id, in: bodiesDirectory))
            }
            let encoder = JSONEncoder()
            for entry in write.entries {
                let data = try encoder.encode(entry)
                encoded += 1
                try writeData(data, entryURL(entry.id, in: entriesDirectory))
            }
            let listed = Set(write.manifest.entries.keys)
            for url in unlistedEntryFiles(in: entriesDirectory, keeping: listed)
                + unlistedBodyFiles(in: bodiesDirectory, keeping: listed) {
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

    /// Also catches an atomic write's crash-orphaned temp file, which carries no `.json` extension.
    private static func unlistedEntryFiles(in entriesDirectory: URL, keeping ids: Set<String>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: entriesDirectory, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            return !ids.contains(url.deletingPathExtension().lastPathComponent)
        }
    }

    private static func unlistedBodyFiles(in bodiesDirectory: URL, keeping ids: Set<String>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bodiesDirectory, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            return url.pathExtension != "txt" || !ids.contains(url.deletingPathExtension().lastPathComponent)
        }
    }

    private func drainWrites() async {
        let queue = writeQueue
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
