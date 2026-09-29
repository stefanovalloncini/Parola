import Foundation
import MachO

public actor LibraryStore {
    public enum LibraryError: Error, LocalizedError {
        case notFound(String)
        case inTrash(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id): return "Library entry \(id) not found."
            case .inTrash: return "This transcript is in Recently Deleted. Restore it to open it."
            }
        }
    }

    /// A few slots, most recently used last: back-and-forth navigation stays free without pinning several multi-megabyte transcripts in memory.
    private struct LoadedEntryCache {
        private var slots: [(id: LibraryEntry.ID, value: LoadedEntry)] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
        }

        mutating func value(for id: LibraryEntry.ID) -> LoadedEntry? {
            guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }
            let slot = slots.remove(at: index)
            slots.append(slot)
            return slot.value
        }

        mutating func insert(_ value: LoadedEntry, for id: LibraryEntry.ID) {
            slots.removeAll { $0.id == id }
            slots.append((id, value))
            if slots.count > capacity { slots.removeFirst(slots.count - capacity) }
        }

        /// A manifest edit refreshes the entry in place; it is not a use, so it leaves recency alone.
        mutating func patch(_ entry: LibraryEntry) {
            guard let index = slots.firstIndex(where: { $0.id == entry.id }) else { return }
            slots[index].value = LoadedEntry(entry: entry, document: slots[index].value.document)
        }

        mutating func remove(_ id: LibraryEntry.ID) {
            slots.removeAll { $0.id == id }
        }

        mutating func removeAll() {
            slots.removeAll()
        }
    }

    /// Who keeps the library's search index up to date on disk.
    public enum Role: Sendable {
        /// The app: it builds, saves and backfills the index and the bundles' manifests.
        case owner
        /// The CLI, the MCP server, an intent outside the app: reads the library beside its owner.
        /// Its index lives in memory, caught up from the bundles, and nothing it reads is written back.
        case reader
    }

    /// Set before the first `shared` access to point it at another folder, as `--library` does.
    public nonisolated(unsafe) static var sharedLibraryOverride: URL?

    /// A reader: every process that reaches for it reads a library the app owns.
    public static let shared: LibraryStore = {
        precondition(
            !isTestProcess,
            "LibraryStore.shared is the user's real library; a test must inject a scratch one."
        )
        return LibraryStore(
            libraryURL: sharedLibraryOverride ?? defaultLibraryURL,
            extraIndexer: SpotlightIndexer(),
            role: .reader
        )
    }()

    /// Whether a test bundle is loaded into this process. Neither `XCTestConfigurationFilePath` nor
    /// `Bundle.main` identifies a `swift test` run — its main bundle is swiftpm-testing-helper and it
    /// loads no XCTest — so the check is on the loaded images, which both runners agree on.
    public static var isTestProcess: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            if String(cString: name).contains(".xctest") { return true }
        }
        return false
    }

    public static var defaultLibraryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Library", directoryHint: .isDirectory)
    }

    public nonisolated let libraryURL: URL
    public nonisolated let role: Role
    private var searchIndex: LibrarySearchIndex
    private let extraIndexer: LibraryIndexer?
    private var cachedActive: [LibraryEntry]?
    private var cachedDeleted: [LibraryEntry]?
    private var cachedLoaded = LoadedEntryCache(capacity: 3)
    private var listCacheEpoch = 0
    /// The library folder's modification date as of the last scan or this store's own last add or removal.
    private var folderStamp: Date?
    /// A reader's view of the owner's index snapshot as of its last `reloadIfChangedElsewhere`.
    private var seenSnapshotStamp: Date?
    private var indexReadyTask: Task<Void, Never>?
    private var searchIndexNeedsCheck = false
    private var digestBackfillTask: Task<Void, Never>?
    private nonisolated let extraIndexerJobs: AsyncStream<@Sendable () async -> Void>.Continuation?
    private nonisolated let didDecodeDocument: (@Sendable () -> Void)?
    private nonisolated let didWriteBundle: (@Sendable () -> Void)?
    private nonisolated let willCatchUpSearchIndex: (@Sendable () async -> Void)?

    public init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.init(libraryURL: libraryURL, extraIndexer: SpotlightIndexer())
    }

    /// Delegates through `storeAt:`, a label this init cannot itself spell, so dropping `seams:` here is a compile error, not a self-delegating recursion.
    public init(libraryURL: URL, extraIndexer: LibraryIndexer?, role: Role = .owner) {
        self.init(storeAt: libraryURL, extraIndexer: extraIndexer, seams: TestSeams(), role: role)
    }

    /// One struct, not two params, so this init's signature can never collide with the public ones by argument count; the hooks run off the actor after a decode and after `add` writes a bundle.
    struct TestSeams: Sendable {
        var didDecodeDocument: (@Sendable () -> Void)?
        var didWriteBundle: (@Sendable () -> Void)?
        var willCatchUpSearchIndex: (@Sendable () async -> Void)?

        init(
            didDecodeDocument: (@Sendable () -> Void)? = nil,
            didWriteBundle: (@Sendable () -> Void)? = nil,
            willCatchUpSearchIndex: (@Sendable () async -> Void)? = nil
        ) {
            self.didDecodeDocument = didDecodeDocument
            self.didWriteBundle = didWriteBundle
            self.willCatchUpSearchIndex = willCatchUpSearchIndex
        }
    }

    init(
        storeAt libraryURL: URL,
        extraIndexer: LibraryIndexer?,
        seams: TestSeams,
        role: Role = .owner
    ) {
        self.libraryURL = libraryURL
        self.role = role
        self.extraIndexer = extraIndexer
        self.didDecodeDocument = seams.didDecodeDocument
        self.didWriteBundle = seams.didWriteBundle
        self.willCatchUpSearchIndex = seams.willCatchUpSearchIndex
        // Extra-indexer calls drain FIFO on one background worker: CoreSpotlight's XPC can
        // stall indefinitely (observed on ad-hoc dev builds), and a best-effort mirror index
        // must never block the library write path.
        if extraIndexer != nil {
            var continuation: AsyncStream<@Sendable () async -> Void>.Continuation?
            let jobs = AsyncStream<@Sendable () async -> Void> { continuation = $0 }
            self.extraIndexerJobs = continuation
            Task.detached(priority: .utility) {
                for await job in jobs { await job() }
            }
        } else {
            self.extraIndexerJobs = nil
        }
        let indexDirectory = Self.indexDirectory(in: libraryURL)
        switch role {
        case .owner:
            // Made here, not by the first index save, which would move the folder's date after a scan took it.
            try? FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            self.searchIndex = LibrarySearchIndex(indexDirectory: indexDirectory)
        case .reader:
            self.searchIndex = LibrarySearchIndex(readingSnapshotIn: indexDirectory)
        }
    }

    deinit {
        extraIndexerJobs?.finish()
    }

    public func list() async -> [LibraryEntry] {
        if let cachedActive { return cachedActive }
        await primeCaches()
        return cachedActive ?? []
    }

    public func listDeleted() async -> [LibraryEntry] {
        if let cachedDeleted { return cachedDeleted }
        await primeCaches()
        return cachedDeleted ?? []
    }

    /// Best first. Ties fall to the most occurrences, then the newest entry, then the id, so a query
    /// answers in the same order every time. Only the first `snippetLimit` matches carry a snippet;
    /// `withSnippets(_:query:)` fills the rest when they are shown.
    public func search(_ query: String, snippetLimit: Int = .max) async -> [LibrarySearchIndex.Match] {
        let index = await readySearchIndex()
        if cachedActive == nil { await primeCaches() }
        let createdAt = Dictionary(
            (cachedActive ?? []).map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let matches = await index.search(query, snippets: false)
        let ranked = matches
            .compactMap { match in createdAt[match.entryID].map { (match: match, createdAt: $0) } }
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                if lhs.match.matchCount != rhs.match.matchCount { return lhs.match.matchCount > rhs.match.matchCount }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.match.entryID < rhs.match.entryID
            }
            .map(\.match)
        guard snippetLimit > 0 else { return ranked }
        let head = await index.withSnippets(Array(ranked.prefix(snippetLimit)), query: query)
        return head + ranked.dropFirst(snippetLimit)
    }

    /// Builds the snippets `search` left empty, for the matches a list is about to show.
    public func withSnippets(_ matches: [LibrarySearchIndex.Match], query: String) async -> [LibrarySearchIndex.Match] {
        await readySearchIndex().withSnippets(matches, query: query)
    }

    /// The opening text of every indexed entry, so a list can show what an entry says, or nil when
    /// `generation` is the one the caller already holds. The index answers from memory; nothing here reads a bundle.
    public func excerpts(after generation: Int) async -> LibrarySearchIndex.Excerpts? {
        await readySearchIndex().excerpts(after: generation)
    }

    /// Writes any pending debounced search-index snapshot to disk. Call before the app terminates.
    public func flush() async {
        await searchIndex.flush()
    }

    /// Bytes held by every bundle in the library, deleted ones included. nil when the directory
    /// cannot be listed.
    public func sizeOnDisk() async -> UInt64? {
        let url = libraryURL
        return await offActorIO(qos: .utility) { Self.bundleBytes(in: url) }
    }

    private static func bundleBytes(in libraryURL: URL) -> UInt64? {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil
        ) else { return nil }
        var total: UInt64 = 0
        for bundle in contents where bundle.pathExtension == "parola" {
            guard let files = manager.enumerator(
                at: bundle,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            ) else { continue }
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                total += UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileSize ?? 0))
            }
        }
        return total
    }

    /// Loads the search index and brings it up to date with the bundles, so the first search or
    /// excerpt read doesn't wait on it. Nothing loads the index before something asks for it.
    public func warmSearchIndex() async {
        await ensureSearchIndexReady()
    }

    /// A reader can swap its index mid catch-up, so callers read only the one this hands back once it is ready.
    private func readySearchIndex() async -> LibrarySearchIndex {
        var index = searchIndex
        for _ in 0..<8 {
            await ensureSearchIndexReady()
            guard index !== searchIndex else { return index }
            index = searchIndex
        }
        // Only exists to terminate: whatever is current gets one more catch-up before anyone reads it.
        await ensureSearchIndexReady()
        return searchIndex
    }

    private func ensureSearchIndexReady() async {
        if indexReadyTask == nil || searchIndexNeedsCheck {
            searchIndexNeedsCheck = false
            // Chained, so two checks never reconcile the same index at once.
            let previous = indexReadyTask
            indexReadyTask = Task {
                await previous?.value
                if await !catchUpSearchIndex() { searchIndexNeedsCheck = true }
            }
        }
        await indexReadyTask?.value
    }

    /// A reader that never searched holds no index to keep current: its first search catches up from the bundles.
    private var keepsSearchIndexCurrent: Bool {
        role == .owner || indexReadyTask != nil
    }

    var hasRequestedSearchIndex: Bool { indexReadyTask != nil }

    /// Reads only the bundles the index lacks or holds older copies of; false when the folder would not list.
    private func catchUpSearchIndex() async -> Bool {
        let index = searchIndex
        await willCatchUpSearchIndex?()
        let url = libraryURL
        let epoch = listCacheEpoch
        let stamp = Self.folderStamp(of: url)
        let scan = await offActorIO(qos: .utility) { [self] in indexScan(at: url) }
        guard let scan else { return false }
        // The list caches want the same scan; skip it if a mutation landed while it ran.
        if cachedActive == nil, epoch == listCacheEpoch { applyScan(scan.entries, folderStamp: stamp) }
        if role == .owner { startSourceDigestBackfill(scan.entries) }
        let staleness = await index.staleness(matching: scan.fingerprints)
        guard !staleness.isCurrent else { return true }
        let indexable = scan.entries.filter {
            $0.deletedAt == nil && (staleness.needsRebuild || staleness.changed.contains($0.id))
        }
        let rebuilt = await offActorIO(qos: .utility) {
            var unreadable = 0
            let entries = indexable.map { entry -> LibrarySearchIndex.RebuildEntry in
                let fingerprint = scan.fingerprints[entry.id] ?? ""
                // Dropping it would leave the index short of the fingerprints and rebuild for ever.
                guard let doc = try? ParolaDocument.read(at: entry.bundleURL) else {
                    unreadable += 1
                    return .init(
                        id: entry.id, title: entry.title, text: "",
                        auxiliaryText: Self.searchAuxiliaryText(
                            notes: entry.segmentNotes, transcript: nil,
                            aiTitle: entry.aiTitle, shortSummary: entry.shortSummary
                        ),
                        fingerprint: fingerprint
                    )
                }
                return .init(
                    id: entry.id,
                    title: entry.title,
                    text: doc.transcript.text,
                    auxiliaryText: Self.searchAuxiliaryText(
                        notes: entry.segmentNotes, transcript: doc.transcript,
                        aiTitle: entry.aiTitle, shortSummary: entry.shortSummary
                    ),
                    boundaries: Self.segmentBoundaries(for: doc.transcript),
                    fingerprint: fingerprint
                )
            }
            return (entries: entries, unreadable: unreadable)
        }
        // One count, never one record per bundle: a library whose folder went unreadable would
        // otherwise write a line for every entry it holds.
        if rebuilt.unreadable > 0 {
            ParolaLog.notice(
                .libraryIndex,
                "bundles indexed on their title and notes alone",
                [.count: .int(rebuilt.unreadable)]
            )
        }
        if staleness.needsRebuild {
            await index.rebuild(entries: rebuilt.entries)
        } else {
            await index.reconcile(entries: rebuilt.entries, removing: staleness.removed)
        }
        return true
    }

    /// Bundles written before the manifest carried a digest pick one up here, once per store, in
    /// the background — a search must never wait on a library's worth of hashing.
    private func startSourceDigestBackfill(_ entries: [LibraryEntry]) {
        guard digestBackfillTask == nil else { return }
        let pending = entries.filter { $0.deletedAt == nil && $0.manifest.sourceDigest == nil }
        guard !pending.isEmpty else { return }
        digestBackfillTask = Task.detached(priority: .utility) { [weak self] in
            for entry in pending {
                guard !Task.isCancelled, let self else { return }
                guard let audio = ParolaDocument.audioURL(in: entry.bundleURL, manifest: entry.manifest),
                      let digest = await SourceDigest.digest(of: audio)
                else { continue }
                await self.stampSourceDigest(digest, for: entry)
            }
        }
    }

    private func stampSourceDigest(_ digest: String, for entry: LibraryEntry) {
        try? ParolaDocument.updateManifest(at: entry.bundleURL) { manifest in
            guard manifest.sourceDigest == nil else { return }
            manifest.sourceDigest = digest
        }
        _ = try? recacheEntry(at: entry.bundleURL)
    }

    func waitForSourceDigestBackfill() async {
        await digestBackfillTask?.value
    }

    private struct IndexScan: Sendable {
        let entries: [LibraryEntry]
        let fingerprints: [String: String]
    }

    /// Soft-deleted bundles stay on disk but leave the index, so the fingerprints the snapshot is
    /// measured against leave them out. `entries` holds the whole scan, for the list caches.
    private nonisolated func indexScan(at libraryURL: URL) -> IndexScan? {
        guard let scanned = scanEntries(at: libraryURL) else { return nil }
        return IndexScan(
            entries: scanned,
            fingerprints: Dictionary(
                scanned.lazy
                    .filter { $0.deletedAt == nil }
                    .map { ($0.id, Self.bundleFingerprint($0.bundleURL)) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// The transcript's size and modification time. A bundle written straight into the library
    /// folder never passes through `index`, so the snapshot is checked against the files themselves.
    /// Indexed manifest fields — the card's title and summary, segment notes — do not move it: they
    /// live outside transcript.json, so a lost index write over them reads as up to date.
    nonisolated static func bundleFingerprint(_ bundleURL: URL) -> String {
        let url = bundleURL.appendingPathComponent("transcript.json")
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = values?.contentModificationDate else { return "absent" }
        return "\(Int(modified.timeIntervalSince1970 * 1000))-\(values?.fileSize ?? 0)"
    }

    private func primeCaches() async {
        let url = libraryURL
        // A mutation landing during the off-actor scan would cache pre-mutation state, so retry under the new epoch; the on-actor last resort stalls every caller and only exists to terminate.
        for _ in 0..<8 {
            let epoch = listCacheEpoch
            let stamp = Self.folderStamp(of: url)
            let entries = await offActorIO { [self] in scanEntries(at: url) }
            if epoch == listCacheEpoch {
                applyScan(entries ?? [], folderStamp: stamp)
                return
            }
        }
        let stamp = Self.folderStamp(of: url)
        applyScan(scanEntries(at: url) ?? [], folderStamp: stamp)
    }

    /// Read before the scan it belongs to, so a write landing during the scan still reads as a change.
    private nonisolated static func folderStamp(of url: URL) -> Date? {
        modificationDate(of: url)
    }

    /// Whether another process saved or removed a bundle since this store last listed the folder.
    /// One stat; false before the first listing, which reads the folder anyway.
    public func folderChangedElsewhere() -> Bool {
        guard let folderStamp else { return false }
        return Self.folderStamp(of: libraryURL) != folderStamp
    }

    /// For a store beside the one that writes the library, such as the MCP server's: forgets what it
    /// read when another process has changed an entry or the search index since the last call. Two
    /// stats when nothing moved. True when it dropped anything.
    @discardableResult
    public func reloadIfChangedElsewhere() async -> Bool {
        var snapshotMoved = false
        if role == .reader {
            let snapshot = Self.modificationDate(of: Self.indexDirectory(in: libraryURL).appendingPathComponent("manifest.json"))
            snapshotMoved = snapshot != seenSnapshotStamp
            seenSnapshotStamp = snapshot
        }
        guard folderChangedElsewhere() || snapshotMoved else { return false }
        dropCaches()
        let index = searchIndex
        if snapshotMoved, indexReadyTask != nil, await !index.refreshFromSnapshot(), index === searchIndex {
            replaceSearchIndex()
        }
        return true
    }

    /// A fresh reader index that loads the snapshot on its next use, caught up by the next reader of it.
    func replaceSearchIndex() {
        searchIndex = LibrarySearchIndex(readingSnapshotIn: Self.indexDirectory(in: libraryURL))
        searchIndexNeedsCheck = true
    }

    private nonisolated static func indexDirectory(in libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent(".search-index", isDirectory: true)
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// After this store adds or removes a bundle, the folder's new date is its own, unless it had already moved before.
    private func adoptFolderStamp(ifUnchangedFrom before: Date?) {
        guard folderStamp != nil, folderStamp == before else { return }
        folderStamp = Self.folderStamp(of: libraryURL)
    }

    private func applyScan(_ entries: [LibraryEntry], folderStamp stamp: Date?) {
        folderStamp = stamp
        cachedActive = entries
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        cachedDeleted = entries
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// nil when the directory is there but its listing failed — a caller that writes an authoritative
    /// index off this scan must not read that as an empty library.
    private nonisolated func scanEntries(at libraryURL: URL) -> [LibraryEntry]? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else {
            guard fm.fileExists(atPath: libraryURL.path) else { return [] }
            ParolaLog.error(.library, "library folder could not be listed")
            return nil
        }
        let decoder = Self.manifestDecoder()
        return contents
            .filter { $0.pathExtension == "parola" }
            .compactMap { try? makeEntry(bundleURL: $0, decoder: decoder) }
    }

    public func load(_ id: LibraryEntry.ID) async throws -> LoadedEntry {
        if let cached = cachedLoaded.value(for: id) {
            return cached
        }
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let doc = try await decodedDocument(at: bundleURL)
        // Bundles written before the manifest carried a duration learn it the first time
        // they're opened, so the library list fills in instead of staying blank forever.
        if role == .owner, doc.manifest.durationSeconds == nil,
           let duration = doc.transcript.durationSeconds, duration > 0 {
            try? ParolaDocument.updateManifest(at: bundleURL) { $0.durationSeconds = duration }
            announceManifestEdit()
        }
        let entry = try makeEntry(bundleURL: bundleURL)
        let loaded = LoadedEntry(entry: entry, document: doc)
        cachedLoaded.insert(loaded, for: id)
        return loaded
    }

    /// Off the actor because a long transcript is megabytes of JSON; a mutation landing mid-decode would hand back pre-mutation content, so retry under the new epoch as `primeCaches` does, with the same on-actor last resort to terminate.
    private func decodedDocument(at bundleURL: URL) async throws -> ParolaDocument {
        for _ in 0..<8 {
            let epoch = listCacheEpoch
            let doc = try await offActorThrowingIO { [didDecodeDocument] in
                let decoded = try Self.readCleanedDocument(at: bundleURL)
                didDecodeDocument?()
                return decoded
            }
            if epoch == listCacheEpoch { return doc }
        }
        return try Self.readCleanedDocument(at: bundleURL)
    }

    /// For a write that starts from disk: `setDurationSeconds` corrects the manifest alone, and
    /// `updateTranscript` would copy transcript.json's old length back over it.
    private nonisolated static func readStoredTranscript(at bundleURL: URL) throws -> Transcript {
        let document = try readCleanedDocument(at: bundleURL)
        var transcript = document.transcript
        if let measured = document.manifest.durationSeconds, measured > 0 {
            transcript.durationSeconds = measured
        }
        return transcript
    }

    private nonisolated static func readCleanedDocument(at bundleURL: URL) throws -> ParolaDocument {
        var doc = try ParolaDocument.read(at: bundleURL)
        // Entries written before the blank-drop moved to assembly time still carry silent VAD
        // chunks as empty rows. The surviving ids stay as they are: `segmentNotes` is keyed by them.
        doc.transcript.segments = doc.transcript.segments.droppingBlankText()
        return doc
    }

    /// The newest active entry imported from these exact bytes. Recently Deleted entries don't
    /// count — the user already threw that copy away.
    public func findEntry(digest: String) async -> LibraryEntry? {
        guard !digest.isEmpty else { return nil }
        if cachedActive == nil { await primeCaches() }
        return (cachedActive ?? []).first { $0.manifest.sourceDigest == digest }
    }

    public func add(
        transcript: Transcript,
        audioSource: URL?,
        category: EntryCategory = .transcription,
        title: String? = nil,
        sourceDigest: String? = nil,
        source: EntrySource? = nil,
        consumesAudio: Bool = false
    ) async throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        let target = bundleURL.appendingPathExtension("parola")
        let stampBefore = Self.folderStamp(of: libraryURL)
        let digest = await resolvedDigest(sourceDigest, for: audioSource)
        var cancelled = false
        do {
            // Off the actor: writing the bundle copies the source media, which can take seconds for long
            // recordings and would stall every other library call on this actor.
            try await offActorThrowingIO { [didWriteBundle] in
                _ = try ParolaDocument.write(
                    transcript: transcript,
                    audioURL: audioSource,
                    to: bundleURL,
                    category: category,
                    titleOverride: title,
                    sourceDigest: digest,
                    entrySource: source,
                    movesAudio: consumesAudio
                )
                didWriteBundle?()
            }
        } catch is CancellationError {
            // A bundle already on disk is listed and indexed before the cancel is reported: the caches
            // are memoized, so skipping the bookkeeping would hide it until the next launch.
            guard FileManager.default.fileExists(atPath: target.path) else { throw CancellationError() }
            cancelled = true
        }
        if cancelled {
            invalidateListCaches()
            // Best effort from here: the caller matches on CancellationError, so a manifest read
            // that fails must not surface as a different error.
            if let entry = try? makeEntry(bundleURL: target) {
                await indexEntry(entry, transcript: transcript)
            }
            throw CancellationError()
        }
        let entry: LibraryEntry
        do {
            entry = try makeEntry(bundleURL: target)
        } catch {
            invalidateListCaches()
            throw error
        }
        patchCaches(with: entry, aheadOfTies: true)
        adoptFolderStamp(ifUnchangedFrom: stampBefore)
        // The caller is about to open what it just saved; it shouldn't have to decode it back.
        var stored = transcript
        stored.segments = stored.segments.droppingBlankText()
        let document = ParolaDocument(
            transcript: stored,
            audioURL: ParolaDocument.audioURL(in: target, manifest: entry.manifest),
            manifest: entry.manifest
        )
        cachedLoaded.insert(LoadedEntry(entry: entry, document: document), for: entry.id)
        await indexEntry(entry, transcript: transcript)
        return entry
    }

    /// The caller's digest when it already hashed the file to check for a duplicate, otherwise one
    /// taken here. A hash that can't be had leaves the bundle without one for the backfill to fill.
    private func resolvedDigest(_ provided: String?, for audioSource: URL?) async -> String? {
        if let provided { return provided }
        guard let audioSource else { return nil }
        return await SourceDigest.digest(of: audioSource)
    }

    public func adopt(parolaBundle url: URL) async throws -> LibraryEntry {
        let sourceDoc = try ParolaDocument.read(at: url)
        let name = uniqueEntryName(at: Date())
        let target = libraryURL.appendingPathComponent("\(name).parola")
        // Stage under a .tmp name: the copy runs off the actor, so a concurrent list scan
        // would otherwise see (and cache) the half-copied bundle.
        let staging = target.appendingPathExtension("tmp")
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        do {
            // Off the actor: bundle copies can be multi-GB and would stall every other library call.
            try await offActorThrowingIO {
                try FileManager.default.copyItem(at: url, to: staging)
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch is CancellationError {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: target)
            throw CancellationError()
        } catch {
            ParolaLog.error(.library, "adopting a bundle failed and was rolled back", [.error: .error(error)])
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: target)
            throw error
        }
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: target)
        await indexEntry(entry, transcript: sourceDoc.transcript)
        return entry
    }

    private func indexEntry(_ entry: LibraryEntry, transcript: Transcript) async {
        let text = transcript.text
        if keepsSearchIndexCurrent {
            await readySearchIndex().index(
                id: entry.id,
                title: entry.title,
                text: text,
                auxiliaryText: Self.searchAuxiliaryText(
                    notes: entry.segmentNotes, transcript: transcript,
                    aiTitle: entry.aiTitle, shortSummary: entry.shortSummary
                ),
                boundaries: Self.segmentBoundaries(for: transcript),
                fingerprint: Self.bundleFingerprint(entry.bundleURL),
                createdAt: entry.createdAt
            )
        }
        guard let extraIndexer else { return }
        let title = entry.title
        enqueueExtraIndexerWork { [id = entry.id, createdAt = entry.createdAt] in
            await extraIndexer.index(id: id, title: title, text: text, createdAt: createdAt)
        }
    }

    /// Extra-indexer calls run FIFO on a background chain: CoreSpotlight's XPC can stall
    /// indefinitely (observed on ad-hoc dev builds), and a best-effort mirror index must
    /// never block the library write path.
    private func enqueueExtraIndexerWork(_ work: @escaping @Sendable () async -> Void) {
        extraIndexerJobs?.yield(work)
    }

    func waitForExtraIndexer() async {
        guard let extraIndexerJobs else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            extraIndexerJobs.yield { cont.resume() }
        }
    }

    /// Where each segment lands in `Transcript.text`, over the blank-dropped list `load` hands the app, so a hit's `segmentIndex` addresses the transcript the app actually holds.
    static func segmentBoundaries(for transcript: Transcript) -> [LibrarySearchIndex.SegmentBoundary] {
        var boundaries: [LibrarySearchIndex.SegmentBoundary] = []
        boundaries.reserveCapacity(transcript.segments.count)
        var offset = 0
        for segment in transcript.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !boundaries.isEmpty { offset += 1 }
            boundaries.append(.init(textOffset: offset, seconds: segment.start))
            offset += trimmed.count
        }
        return boundaries
    }

    /// `transcript` is nil for a bundle whose transcript is unreadable; its manifest notes still index.
    static func searchAuxiliaryText(
        notes: [String: String],
        transcript: Transcript?,
        aiTitle: String?,
        shortSummary: String?
    ) -> String {
        var parts: [String] = []
        if let aiTitle, !aiTitle.isEmpty { parts.append(aiTitle) }
        if let shortSummary, !shortSummary.isEmpty { parts.append(shortSummary) }
        if let summary = transcript?.summary?.text, !summary.isEmpty { parts.append(summary) }
        parts.append(contentsOf: notes.sorted { $0.key < $1.key }.map(\.value))
        parts.append(contentsOf: transcript?.uniqueSpeakers ?? [])
        return parts.joined(separator: "\n")
    }

    private func deindexEntry(id: String) async {
        if keepsSearchIndexCurrent {
            await readySearchIndex().remove(id)
        }
        guard let extraIndexer else { return }
        enqueueExtraIndexerWork {
            await extraIndexer.deindex(id: id)
        }
    }

    /// Overwrites the transcript.json inside an existing bundle, bumps the manifest `updatedAt`,
    /// and (when `reindex` is true) re-indexes the entry so search and Spotlight reflect the edited text.
    /// Pass `reindex: false` for timing-only nudges where segment text is unchanged — saves the index hop.
    public func updateTranscript(
        _ transcript: Transcript,
        for id: LibraryEntry.ID,
        at now: Date = Date(),
        reindex: Bool = true
    ) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
        cachedLoaded.remove(id)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(transcript)
            try data.write(to: transcriptURL, options: .atomic)
            try ParolaDocument.updateManifest(at: bundleURL) { manifest in
                manifest.updatedAt = now
                manifest.wordCount = transcript.wordCount
                if let duration = transcript.durationSeconds, duration > 0 {
                    manifest.durationSeconds = duration
                }
            }
        } catch {
            // transcript.json lands before the manifest, so a throw in between puts disk ahead of memory.
            ParolaLog.error(.library, "transcript write left disk ahead of memory", [.error: .error(error)])
            invalidateListCaches()
            throw error
        }
        let entry = try recacheEntry(at: bundleURL)
        if reindex {
            await indexEntry(entry, transcript: transcript)
        } else if keepsSearchIndexCurrent {
            // transcript.json still moved, and the snapshot's fingerprint has to follow or the
            // next launch reads the newer file as a stale entry and indexes it again.
            await readySearchIndex().refreshFingerprint(Self.bundleFingerprint(entry.bundleURL), for: entry.id)
        }
    }

    /// Changes the entry's transcript in place and returns what it holds afterwards. The transform
    /// runs between the read and the write with nothing suspended in between, so an edit that lands
    /// alongside it is not reverted; a transform that changes nothing writes nothing.
    @discardableResult
    public func mutateTranscript(
        for id: LibraryEntry.ID,
        reindex: Bool = true,
        _ transform: @Sendable (inout Transcript) -> Void
    ) async throws -> Transcript {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let stored = try Self.readStoredTranscript(at: bundleURL)
        var transcript = stored
        transform(&transcript)
        guard transcript != stored else { return stored }
        try await updateTranscript(transcript, for: id, reindex: reindex)
        return transcript
    }

    /// Re-stamps the engine and language on an entry the user transcribed again. `updateTranscript`
    /// leaves them alone, so without this the rows keep naming the model of the run that was replaced.
    public func setTranscriptionDetails(modelName: String, language: String, for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.modelName = modelName
            manifest.language = language
        }
        try recacheEntry(at: bundleURL)
    }

    /// Changes the category of an entry.
    public func setCategory(_ category: EntryCategory, for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.category = category
        }
        try recacheEntry(at: bundleURL)
    }

    /// Toggles or sets the pinned flag on an entry.
    public func setPinned(_ pinned: Bool, for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.pinned = pinned
        }
        try recacheEntry(at: bundleURL)
    }

    /// Renames an entry's display title by storing it in the manifest's `title` field,
    /// then re-indexes so search matches the new title.
    public func renameEntry(_ id: LibraryEntry.ID, to newName: String) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.title = trimmed
        }
        let entry = try recacheEntry(at: bundleURL)
        if let transcript = await transcriptForReindex(id, at: bundleURL) {
            await indexEntry(entry, transcript: transcript)
        }
    }

    /// Replaces the entry's translation, or clears it when `translation` is nil. Translations are
    /// not searchable, so this write skips the index.
    public func setTranslation(_ translation: TranscriptTranslation?, for id: LibraryEntry.ID) async throws {
        try await mutateTranscript(for: id, reindex: false) { $0.translation = translation }
    }

    /// Replaces the entry's chapters, and the copy its summary keeps, or clears them when `chapters` is nil.
    public func setChapters(_ chapters: [Chapter]?, for id: LibraryEntry.ID) async throws {
        try await mutateTranscript(for: id, reindex: false) { transcript in
            transcript.chapters = chapters
            if let chapters { transcript.summary?.chapters = chapters }
        }
    }

    /// Replaces the action items found on their own, or clears them when `items` is nil.
    public func setActionItems(_ items: [ActionItem]?, for id: LibraryEntry.ID) async throws {
        try await mutateTranscript(for: id, reindex: false) { $0.actionItems = items }
    }

    /// Replaces the entry's summary, or clears it when `summary` is nil, and re-indexes: summary text is searchable.
    /// `chapters`, when given, replaces the entry's chapter list in the same write, so the two never disagree on disk.
    public func setSummary(_ summary: Summary?, chapters: [Chapter]? = nil, for id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        var transcript = try Self.readStoredTranscript(at: bundleURL)
        let keptChapters = chapters ?? transcript.chapters
        guard transcript.summary != summary || transcript.chapters != keptChapters else {
            // The debounced transcript save can land this summary first, with indexing off.
            await indexEntry(try recacheEntry(at: bundleURL), transcript: transcript)
            return
        }
        transcript.summary = summary
        transcript.chapters = keptChapters
        try await updateTranscript(transcript, for: id, reindex: true)
    }

    /// Writes the on-device title and summary shown on the entry's card and makes both searchable.
    /// Returns the entry as it now stands, so a caller can update its row without listing the library.
    @discardableResult
    public func setCardMetadata(aiTitle: String?, shortSummary: String?, for id: LibraryEntry.ID) async throws -> LibraryEntry {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        var before: (aiTitle: String?, shortSummary: String?) = (nil, nil)
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            before = (manifest.aiTitle, manifest.shortSummary)
            manifest.aiTitle = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            manifest.shortSummary = shortSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        let entry = try recacheEntry(at: bundleURL)
        let old = Self.searchAuxiliaryText(notes: [:], transcript: nil, aiTitle: before.aiTitle, shortSummary: before.shortSummary)
        let new = Self.searchAuxiliaryText(notes: [:], transcript: nil, aiTitle: entry.aiTitle, shortSummary: entry.shortSummary)
        guard old != new, keepsSearchIndexCurrent else { return entry }
        if await !readySearchIndex().replaceAuxiliaryText(old, with: new, for: id),
           let transcript = await transcriptForReindex(id, at: bundleURL) {
            await indexEntry(entry, transcript: transcript)
        }
        return entry
    }

    /// Appends a delivery receipt to the entry. Receipts are not searchable, so this write skips
    /// the index.
    public func appendDelivery(_ receipt: DeliveryReceipt, for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.deliveries.append(receipt)
        }
        try recacheEntry(at: bundleURL)
    }

    /// Replaces the entry's speaker-to-person map. The names themselves live in the transcript, so
    /// this write skips the index.
    public func setSpeakerAssignments(_ assignments: [String: UUID], for id: LibraryEntry.ID) throws {
        try mutateSpeakerAssignments(for: id) { $0 = assignments }
    }

    /// Changes the entry's speaker-to-person map in place and returns what it holds afterwards.
    /// The transform runs inside the actor, so two assignments in flight can't drop each other's key.
    @discardableResult
    public func mutateSpeakerAssignments(
        for id: LibraryEntry.ID,
        _ transform: @Sendable (inout [String: UUID]) -> Void
    ) throws -> [String: UUID] {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        var updated: [String: UUID] = [:]
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            transform(&manifest.speakerAssignments)
            updated = manifest.speakerAssignments
        }
        try recacheEntry(at: bundleURL)
        return updated
    }

    /// Sets a note for a segment within an entry, then re-indexes so notes are searchable.
    /// Pass `nil` or empty to clear it.
    public func setSegmentNote(_ note: String?, segmentID: Int, for id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            let key = String(segmentID)
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                manifest.segmentNotes[key] = trimmed
            } else {
                manifest.segmentNotes.removeValue(forKey: key)
            }
        }
        let entry = try recacheEntry(at: bundleURL)
        if let transcript = await transcriptForReindex(id, at: bundleURL) {
            await indexEntry(entry, transcript: transcript)
        }
    }

    /// Replaces the whole note map in one write, for an edit that renumbered the segments the
    /// notes are keyed by. Re-indexes once, the way `setSegmentNote` does for a single note.
    public func setSegmentNotes(_ notes: [String: String], for id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.segmentNotes = notes
        }
        let entry = try recacheEntry(at: bundleURL)
        if let transcript = await transcriptForReindex(id, at: bundleURL) {
            await indexEntry(entry, transcript: transcript)
        }
    }

    public func setSegmentFavorite(_ isFavorite: Bool, segmentID: Int, for id: LibraryEntry.ID) throws {
        try updateFavorites(for: id) { favorites in
            if isFavorite { favorites.insert(segmentID) } else { favorites.remove(segmentID) }
        }
    }

    public func setFavoriteSegments(_ ids: Set<Int>, for id: LibraryEntry.ID) throws {
        try updateFavorites(for: id) { $0 = ids }
    }

    private func updateFavorites(for id: LibraryEntry.ID, _ mutate: (inout Set<Int>) -> Void) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            var favorites = Set(manifest.favoriteSegments)
            mutate(&favorites)
            manifest.favoriteSegments = favorites.sorted()
        }
        try recacheEntry(at: bundleURL)
    }

    /// A manifest edit leaves transcript.json alone, so an open document is still current; fall back
    /// to disk — off the actor, word timings and all — only when it isn't cached.
    private func transcriptForReindex(_ id: LibraryEntry.ID, at bundleURL: URL) async -> Transcript? {
        if let cached = cachedLoaded.value(for: id) { return cached.document.transcript }
        return await offActorIO { try? ParolaDocument.read(at: bundleURL).transcript }
    }

    /// Replaces the labels on a library entry. Empty array clears them.
    public func setLabels(_ labels: [String], for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            var seen = Set<String>()
            manifest.labels = labels.compactMap { name -> String? in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return trimmed
            }
        }
        try recacheEntry(at: bundleURL)
    }

    /// Records the length the entry's media actually measures, for a transcript that stored a wrong one.
    public func setDurationSeconds(_ seconds: Double, for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.durationSeconds = seconds
        }
        try recacheEntry(at: bundleURL)
    }

    /// Stamps the entry's `lastOpenedAt` so the library can show when it was last viewed.
    public func markOpened(id: LibraryEntry.ID, at now: Date = Date()) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.lastOpenedAt = now
        }
        // Nothing a reader shows depends on when an entry was opened, and opens are frequent.
        try recacheEntry(at: bundleURL, announcing: false)
    }

    /// Re-reads the one manifest a mutation touched and folds it into the caches, so a single-entry
    /// edit doesn't force the next read to re-decode every bundle in the library.
    @discardableResult
    private func recacheEntry(at bundleURL: URL, announcing: Bool = true) throws -> LibraryEntry {
        do {
            let entry = try makeEntry(bundleURL: bundleURL)
            patchCaches(with: entry)
            if announcing { announceManifestEdit() }
            return entry
        } catch {
            ParolaLog.error(.library, "entry recache failed, caches dropped", [.error: .error(error)])
            invalidateListCaches()
            cachedLoaded.removeAll()
            throw error
        }
    }

    /// A manifest edit moves no date a reader checks, so the owner moves the folder's and keeps the new one as its own.
    private func announceManifestEdit() {
        guard role == .owner else { return }
        let before = Self.folderStamp(of: libraryURL)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: libraryURL.path)
        adoptFolderStamp(ifUnchangedFrom: before)
    }

    /// `aheadOfTies` for an entry just added: made this second, it is still the newest of them.
    private func patchCaches(with entry: LibraryEntry, aheadOfTies: Bool = false) {
        cachedActive = patched(cachedActive, with: entry, belongs: entry.deletedAt == nil) {
            aheadOfTies ? $0.createdAt >= $1.createdAt : $0.createdAt > $1.createdAt
        }
        cachedDeleted = patched(cachedDeleted, with: entry, belongs: entry.deletedAt != nil) {
            ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
        }
        cachedLoaded.patch(entry)
        // A patch is a write like any other: an in-flight primeCaches must re-scan rather than cache
        // the snapshot it took before this manifest landed.
        listCacheEpoch &+= 1
    }

    private func patched(
        _ cache: [LibraryEntry]?,
        with entry: LibraryEntry,
        belongs: Bool,
        orderedBefore: (LibraryEntry, LibraryEntry) -> Bool
    ) -> [LibraryEntry]? {
        guard var list = cache else { return nil }
        list.removeAll { $0.id == entry.id }
        guard belongs else { return list }
        let index = list.firstIndex { orderedBefore(entry, $0) } ?? list.count
        list.insert(entry, at: index)
        return list
    }

    private func removeFromCaches(id: LibraryEntry.ID) {
        cachedActive?.removeAll { $0.id == id }
        cachedDeleted?.removeAll { $0.id == id }
        cachedLoaded.remove(id)
        listCacheEpoch &+= 1
    }

    /// Soft-deletes by stamping `deletedAt`. The bundle stays on disk so it can be restored,
    /// but the entry leaves search and Spotlight immediately.
    public func delete(_ id: LibraryEntry.ID, at now: Date = Date()) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.deletedAt = now
        }
        try recacheEntry(at: bundleURL)
        await deindexEntry(id: id)
    }

    /// Reverses a soft-delete by clearing `deletedAt` and re-indexing the entry.
    public func restore(_ id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.deletedAt = nil
        }
        if let entry = try? recacheEntry(at: bundleURL),
           let transcript = await transcriptForReindex(id, at: bundleURL) {
            await indexEntry(entry, transcript: transcript)
        }
    }

    /// Permanently removes a bundle from disk.
    public func purge(_ id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let stampBefore = Self.folderStamp(of: libraryURL)
        try FileManager.default.removeItem(at: bundleURL)
        removeFromCaches(id: id)
        adoptFolderStamp(ifUnchangedFrom: stampBefore)
        await deindexEntry(id: id)
    }

    public struct VerificationReport: Sendable, Equatable {
        public enum Issue: Sendable, Equatable {
            case missingManifest
            case unreadableManifest
            case missingTranscript
            case versionTooNew(Int)
        }

        public struct Problem: Sendable, Equatable {
            public let bundleURL: URL
            public let issue: Issue

            public init(bundleURL: URL, issue: Issue) {
                self.bundleURL = bundleURL
                self.issue = issue
            }
        }

        public let healthy: [LibraryEntry]
        public let problems: [Problem]

        public init(healthy: [LibraryEntry], problems: [Problem]) {
            self.healthy = healthy
            self.problems = problems
        }
    }

    /// Walks every `.parola` bundle in the library and reports half-written or invalid ones.
    public func verify() async -> VerificationReport {
        let url = libraryURL
        let stampsDigests = role == .owner
        let report = await offActorIO { Self.verifySync(at: url, stampingDigests: stampsDigests) }
        // The walk stamps missing digests as it goes, so every cached manifest may now be stale.
        if stampsDigests { invalidateListCaches() }
        return report
    }

    nonisolated static func verifySync(at libraryURL: URL, stampingDigests: Bool = true) -> VerificationReport {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else {
            return VerificationReport(healthy: [], problems: [])
        }
        var healthy: [LibraryEntry] = []
        var problems: [VerificationReport.Problem] = []
        for bundleURL in contents where bundleURL.pathExtension == "parola" {
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                problems.append(.init(bundleURL: bundleURL, issue: .missingManifest))
                continue
            }
            guard let data = try? Data(contentsOf: manifestURL) else {
                problems.append(.init(bundleURL: bundleURL, issue: .unreadableManifest))
                continue
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(ParolaDocument.Manifest.self, from: data) else {
                problems.append(.init(bundleURL: bundleURL, issue: .unreadableManifest))
                continue
            }
            if manifest.version > ParolaDocument.Manifest.currentVersion {
                problems.append(.init(bundleURL: bundleURL, issue: .versionTooNew(manifest.version)))
                continue
            }
            let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
            guard fm.fileExists(atPath: transcriptURL.path) else {
                problems.append(.init(bundleURL: bundleURL, issue: .missingTranscript))
                continue
            }
            healthy.append(
                LibraryEntry(
                    id: entryID(for: bundleURL),
                    bundleURL: bundleURL,
                    manifest: stampingDigests ? stampingDigest(manifest, at: bundleURL) : manifest
                )
            )
        }
        return VerificationReport(healthy: healthy, problems: problems)
    }

    /// The owner's verify already walks every bundle, so it is where a pre-digest bundle picks one up.
    private nonisolated static func stampingDigest(
        _ manifest: ParolaDocument.Manifest,
        at bundleURL: URL
    ) -> ParolaDocument.Manifest {
        guard manifest.sourceDigest == nil,
              let audio = ParolaDocument.audioURL(in: bundleURL, manifest: manifest),
              let digest = (try? SourceDigest.compute(contentsOf: audio)) ?? nil
        else { return manifest }
        try? ParolaDocument.updateManifest(at: bundleURL) { $0.sourceDigest = digest }
        var stamped = manifest
        stamped.sourceDigest = digest
        return stamped
    }

    /// What one Recently-Deleted purge removed, and how many bundles it left on disk.
    public struct PurgeResult: Sendable, Equatable {
        public let purgedIDs: [LibraryEntry.ID]
        public let failed: Int

        public var purged: Int { purgedIDs.count }
    }

    /// Hard-deletes any soft-deleted entry whose `deletedAt` is older than `days` before `now`.
    @discardableResult
    public func purgeDeletedOlderThan(days: Int, now: Date) async -> PurgeResult {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        if cachedDeleted == nil { await primeCaches() }
        let toPurge = (cachedDeleted ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        let stampBefore = Self.folderStamp(of: libraryURL)
        var purgedIDs: [LibraryEntry.ID] = []
        var failed = 0
        var firstFailure: (any Error)?
        for entry in toPurge {
            do {
                try FileManager.default.removeItem(at: entry.bundleURL)
                removeFromCaches(id: entry.id)
                await deindexEntry(id: entry.id)
                purgedIDs.append(entry.id)
            } catch {
                failed += 1
                if firstFailure == nil { firstFailure = error }
                continue
            }
        }
        if let firstFailure {
            ParolaLog.error(
                .library, "deleted entries could not be purged",
                [.count: .int(failed), .error: .error(firstFailure)]
            )
            // A delete that failed partway can leave a bundle the cached entry no longer describes.
            invalidateListCaches()
        }
        adoptFolderStamp(ifUnchangedFrom: stampBefore)
        return PurgeResult(purgedIDs: purgedIDs, failed: failed)
    }

    private func invalidateListCaches() {
        cachedActive = nil
        cachedDeleted = nil
        listCacheEpoch &+= 1
    }

    /// Drops every in-memory cache so the next read re-scans disk, and has the next search catch the
    /// index up with the bundles. The app's `--test-mode` reset wipes the library directory directly,
    /// behind this actor's back; without this the stale list cache would resurrect entries whose bundles are already gone.
    public func dropCaches() {
        cachedActive = nil
        cachedDeleted = nil
        folderStamp = nil
        cachedLoaded.removeAll()
        listCacheEpoch &+= 1
        searchIndexNeedsCheck = true
    }

    private nonisolated func makeEntry(bundleURL: URL) throws -> LibraryEntry {
        try makeEntry(bundleURL: bundleURL, decoder: Self.manifestDecoder())
    }

    private nonisolated func makeEntry(bundleURL: URL, decoder: JSONDecoder) throws -> LibraryEntry {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: data)
        guard manifest.version <= ParolaDocument.Manifest.currentVersion else {
            throw ParolaError.ioError("Parola document version \(manifest.version) is newer than this app understands.")
        }
        return LibraryEntry(id: Self.entryID(for: bundleURL), bundleURL: bundleURL, manifest: manifest)
    }

    /// Copied into native storage: an id left bridged from NSURL is Unicode-normalised on every list-diff hash.
    private nonisolated static func entryID(for bundleURL: URL) -> LibraryEntry.ID {
        var id = bundleURL.deletingPathExtension().lastPathComponent
        id.makeContiguousUTF8()
        return id
    }

    /// One per scan, never a shared static: `makeEntry` is nonisolated and runs both on the actor and on the off-actor scan.
    private nonisolated static func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func uniqueEntryName(at date: Date) -> String {
        // Full UUID (122 bits), not a truncated prefix — a collision would overwrite an existing bundle.
        let prefix = isoBasic(date)
        let short = UUID().uuidString.lowercased()
        return "\(prefix)-\(short)"
    }

    private nonisolated func isoBasic(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }
}

/// GCD, not `Task.detached`: a detached job resuming actor work around these NSURL-bridging calls has crashed with EXC_ARM_DA_ALIGN.
private func offActorIO<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}

/// The hop cannot be cancelled once running, so the checks bracket it: one pass of `work`, not eight.
private func offActorThrowingIO<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let value: T = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try work() }) }
    }
    try Task.checkCancellation()
    return value
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
