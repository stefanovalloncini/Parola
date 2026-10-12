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
        let tokens: [String]
        let counts: [Int]
        /// Parallel to `tokens`: where the token first occurs in the body, `noOffset` for title-only tokens.
        let offsets: [Int]
        let boundaryOffsets: [Int]
        let boundaryCentiseconds: [Int]
        let fingerprint: String
        /// Cut from the body when the entry is indexed; nil when the body has nothing to quote.
        let excerpt: String?
        /// Names this installed state, so a snippet built across a suspension can tell the entry moved.
        var revision = 0
    }

    private struct SnapshotEntry: Codable, Sendable {
        let id: String
        let title: String
        let excerpt: String?
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

    private struct PreparedEntry: Sendable {
        let id: String
        let entry: IndexedEntry
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

    private var entries: [String: IndexedEntry] = [:]
    private var inverted: [String: Set<String>] = [:]
    private var excerptsByEntry: [String: String] = [:]
    private var excerptsGeneration = 0
    private var dirtyEntryIDs: Set<String> = []
    private var dirtyBodyIDs: Set<String> = []
    private var pendingBodies: [String: PendingBody] = [:]
    private var bodySequence = 0
    private var revisionCounter = 0
    private var indexTickets: [String: Int] = [:]
    private var ticketCounter = 0
    private var sortedTokens: [String]?
    private var isLoaded = false
    private var isDirty = false
    private var legacySnapshotPresent = false
    private var rebuildNeed: RebuildNeed = .none
    private var snapshotWriteFailing = false
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
    // .default, not .utility: the quit path blocks the main thread on a plain semaphore, which donates no priority.
    private let writeQueue = DispatchQueue(label: "com.parola.search-index-write", qos: .default)
    private let latestGeneration = OSAllocatedUnfairLock(initialState: 0)
    private(set) var snapshotGeneration = 0
    private(set) var entriesEncoded = 0
    private(set) var vocabularySorts = 0
    private(set) var entriesDecoded = 0

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
        persists: Bool = true
    ) {
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
        let prepared = await Self.tokenizeOffActor([RebuildEntry(
            id: id, title: title, text: text, auxiliaryText: auxiliaryText,
            boundaries: boundaries, fingerprint: fingerprint
        )])
        guard indexTickets[id] == ticket, let prepared = prepared.first else { return }
        indexTickets[id] = nil
        removeFromIndex(id)
        install(prepared.entry, body: prepared.body, for: id)
        scheduleSave()
    }

    /// Swaps one piece of an entry's auxiliary text for another without tokenizing the rest again.
    /// False when the entry isn't indexed, so the caller can index it whole instead.
    public func replaceAuxiliaryText(_ old: String, with new: String, for id: String) async -> Bool {
        await ensureLoaded()
        guard let entry = entries[id] else { return false }
        var tallies: [String: Tally] = [:]
        for (position, token) in entry.tokens.enumerated() {
            tallies[token] = Tally(
                count: position < entry.counts.count ? entry.counts[position] : 1,
                offset: position < entry.offsets.count ? entry.offsets[position] : Self.noOffset
            )
        }
        Self.enumerateTokens(in: old) { token, _ in tallies[token]?.count -= 1 }
        Self.enumerateTokens(in: new) { token, _ in tallies[token, default: Tally()].count += 1 }
        // A token the body holds keeps its place however the card changes; one only the old card held goes.
        tallies = tallies.filter { $0.value.count > 0 || $0.value.offset != Self.noOffset }
        let tokens = tallies.keys.sorted()
        let replaced = IndexedEntry(
            title: entry.title,
            tokens: tokens,
            counts: tokens.map { max(1, tallies[$0]?.count ?? 1) },
            offsets: tokens.map { tallies[$0]?.offset ?? Self.noOffset },
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint,
            excerpt: entry.excerpt
        )
        removeFromIndex(id)
        install(replaced, body: nil, for: id)
        scheduleSave()
        return true
    }

    public func remove(_ id: String) async {
        await ensureLoaded()
        indexTickets[id] = nil
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
            results.append(Match(
                entryID: id,
                score: score,
                matchCount: hits[id] ?? 0,
                snippet: "",
                highlights: [],
                firstHit: earliest[id].flatMap { Self.firstHit(atOffset: $0.offset, in: entry) }
            ))
        }
        return snippets ? await withSnippets(results, query: query) : results
    }

    /// The matches with their snippets built, as `search` builds them; one whose entry has left the index comes back as it was.
    public func withSnippets(_ matches: [Match], query: String) async -> [Match] {
        let queryTokens = Set(Self.tokenize(query))
        guard !queryTokens.isEmpty, !matches.isEmpty else { return matches }
        await ensureLoaded()
        var captured: [String: IndexedEntry] = [:]
        for match in matches {
            if let entry = entries[match.entryID] { captured[match.entryID] = entry }
        }
        let bodies = await bodies(of: Array(captured.keys))
        return matches.map { match in
            guard let entry = captured[match.entryID], entries[match.entryID]?.revision == entry.revision,
                  let body = bodies[match.entryID] else { return match }
            let snippet = Self.snippet(for: queryTokens, body: body, in: entry)
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
        guard let existing = entries[id], existing.fingerprint != fingerprint else { return }
        let updated = IndexedEntry(
            title: existing.title,
            tokens: existing.tokens,
            counts: existing.counts,
            offsets: existing.offsets,
            boundaryOffsets: existing.boundaryOffsets,
            boundaryCentiseconds: existing.boundaryCentiseconds,
            fingerprint: fingerprint,
            excerpt: existing.excerpt,
            revision: existing.revision
        )
        entries[id] = updated
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
        inverted.removeAll()
        dirtyEntryIDs.removeAll()
        dirtyBodyIDs.removeAll()
        pendingBodies.removeAll()
        indexTickets.removeAll()
        sortedTokens = nil
        for entry in prepared {
            install(entry.entry, body: entry.body, for: entry.id)
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
            install(entry.entry, body: entry.body, for: entry.id)
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
            install(entry.entry, body: nil, for: entry.id)
        }
        entriesDecoded &+= changes.decoded.count
        snapshotStamp = stamp
        snapshotListed = changes.listed
        return true
    }

    /// An id with no body anywhere comes back empty, as a body with nothing to quote does.
    private func bodies(of ids: [String]) async -> [String: String] {
        var found: [String: String] = [:]
        var onDisk: [String] = []
        for id in ids {
            if let pending = pendingBodies[id] { found[id] = pending.text } else { onDisk.append(id) }
        }
        guard !onDisk.isEmpty else { return found }
        let directory = Self.bodiesDirectory(in: indexDirectory)
        let read = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.readBodies(onDisk, in: directory))
            }
        }
        return found.merging(read) { memory, _ in memory }
    }

    private static func readBodies(_ ids: [String], in directory: URL) -> [String: String] {
        var texts = [String](repeating: "", count: ids.count)
        texts.withUnsafeMutableBufferPointer { buffer in
            // Each iteration owns its slot, so the shared buffer never races.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: ids.count) { position in
                guard let data = try? Data(contentsOf: bodyURL(ids[position], in: directory)) else { return }
                slots[position] = String(decoding: data, as: UTF8.self)
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(ids, texts))
    }

    private func discardBody(of id: String) {
        pendingBodies.removeValue(forKey: id)
        dirtyBodyIDs.remove(id)
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
            inverted = state.inverted
            snapshotListed = Set(state.entries.keys)
            entriesDecoded &+= state.entries.count
            sortedTokens = nil
            excerptsByEntry = state.entries.compactMapValues(\.excerpt)
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
        var entries: [String: IndexedEntry] = [:]
        var inverted: [String: Set<String>] = [:]
        entries.reserveCapacity(decoded.count)
        for (id, entry) in zip(ids, decoded) {
            // A file left behind by a write that failed under a manifest a later save wrote: stale, not current.
            guard entry.id == id, manifest.entries[id] == entry.fingerprint else {
                return LoadResult(outcome: .staleDiscarded, legacySnapshotPresent: legacy)
            }
            entries[entry.id] = indexedEntry(from: entry)
            for token in entry.tokens {
                inverted[token, default: []].insert(entry.id)
            }
        }
        return LoadResult(
            outcome: .loaded(LoadedState(entries: entries, inverted: inverted)),
            legacySnapshotPresent: legacy
        )
    }

    private static func indexedEntry(from entry: SnapshotEntry) -> IndexedEntry {
        IndexedEntry(
            title: entry.title,
            tokens: entry.tokens,
            counts: entry.counts,
            offsets: entry.offsets,
            boundaryOffsets: entry.boundaryOffsets,
            boundaryCentiseconds: entry.boundaryCentiseconds,
            fingerprint: entry.fingerprint,
            excerpt: entry.excerpt
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
            prepared.append(PreparedEntry(id: id, entry: indexedEntry(from: entry), body: ""))
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

    private static func tokenizeOffActor(_ rebuilt: [RebuildEntry]) async -> [PreparedEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
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
                slots[position] = PreparedEntry(
                    id: source.id,
                    entry: makeIndexedEntry(
                        title: source.title,
                        text: source.text,
                        auxiliaryText: source.auxiliaryText,
                        boundaries: source.boundaries,
                        fingerprint: source.fingerprint
                    ),
                    body: source.text
                )
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
    ) -> IndexedEntry {
        var tallies: [String: Tally] = [:]
        enumerateTokens(in: title) { token, _ in tallies[token, default: Tally()].count += 1 }
        enumerateTokens(in: text) { token, offset in tallies[token, default: Tally()].add(at: offset) }
        enumerateTokens(in: auxiliaryText) { token, _ in tallies[token, default: Tally()].count += 1 }
        let tokens = tallies.keys.sorted()
        return IndexedEntry(
            title: title,
            tokens: tokens,
            counts: tokens.map { tallies[$0]?.count ?? 0 },
            offsets: tokens.map { tallies[$0]?.offset ?? noOffset },
            boundaryOffsets: boundaries.map(\.textOffset),
            boundaryCentiseconds: boundaries.map { centiseconds($0.seconds) },
            fingerprint: fingerprint,
            excerpt: excerpt(from: text, maxLength: excerptLength)
        )
    }

    /// A nil `body` leaves the one already held or on disk as it is.
    private func install(_ entry: IndexedEntry, body: String?, for id: String) {
        var entry = entry
        revisionCounter &+= 1
        entry.revision = revisionCounter
        entries[id] = entry
        if let body {
            bodySequence &+= 1
            pendingBodies[id] = PendingBody(text: body, sequence: bodySequence)
            dirtyBodyIDs.insert(id)
        }
        if excerptsByEntry[id] != entry.excerpt {
            excerptsByEntry[id] = entry.excerpt
            excerptsGeneration &+= 1
        }
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
            excerpt: entry.excerpt,
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

    private static func snippet(for queryTokens: Set<String>, body: String, in entry: IndexedEntry) -> (text: String, highlights: [Highlight]) {
        makeSnippet(text: body, tokens: queryTokens, hit: earliestHit(of: queryTokens, in: entry))
    }

    /// Where the body first holds a word some query token starts; at a tie the longer token wins, never set order.
    private static func earliestHit(of queryTokens: Set<String>, in entry: IndexedEntry) -> Hit? {
        var best: Hit?
        for queryToken in queryTokens {
            // The same range `search` reads: sorted by scalars, then held to the prefix by characters.
            let lower = firstIndex(in: entry.tokens, atLeast: queryToken)
            let upper = firstIndex(in: entry.tokens, atLeast: queryToken + "\u{10FFFF}")
            for position in lower..<upper where entry.tokens[position].hasPrefix(queryToken) {
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
            entries: pending.compactMap { id in entries[id].map { Self.snapshotEntry(id: id, entry: $0) } },
            bodies: pendingBodyIDs.compactMap { id in
                pendingBodies[id].map { BodyWrite(id: id, text: $0.text, sequence: $0.sequence) }
            },
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
            releaseBodies(write.bodies)
        case .superseded:
            // The entry files landed; the newer generation writes the manifest that lists them.
            releaseBodies(write.bodies)
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
            dirtyBodyIDs.formUnion(pendingBodyIDs.filter { pendingBodies[$0] != nil })
            isDirty = true
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

    /// The manifest lands last, so a write interrupted anywhere before it reads as stale, never as complete.
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
        let contents = (try? FileManager.default.contentsOfDirectory(at: bodiesDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { url in
            url.pathExtension != "txt" || !ids.contains(url.deletingPathExtension().lastPathComponent)
        }
    }

    private func drainWrites() async {
        let queue = writeQueue
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
