import Foundation

public actor LibraryStore {
    public enum LibraryError: Error, LocalizedError {
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id): return "Library entry \(id) not found."
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

    public static let shared = LibraryStore()
    public static var defaultLibraryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Library", directoryHint: .isDirectory)
    }

    public nonisolated let libraryURL: URL
    private let searchIndex: LibrarySearchIndex
    private let extraIndexer: LibraryIndexer?
    private var cachedActive: [LibraryEntry]?
    private var cachedDeleted: [LibraryEntry]?
    private var cachedLoaded = LoadedEntryCache(capacity: 3)
    private var listCacheEpoch = 0
    private var indexReadyTask: Task<Void, Never>?
    private nonisolated let extraIndexerJobs: AsyncStream<@Sendable () async -> Void>.Continuation?
    private nonisolated let didDecodeDocument: (@Sendable () -> Void)?
    private nonisolated let didWriteBundle: (@Sendable () -> Void)?

    public init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.init(libraryURL: libraryURL, extraIndexer: SpotlightIndexer())
    }

    public init(libraryURL: URL, extraIndexer: LibraryIndexer?) {
        self.init(
            libraryURL: libraryURL, extraIndexer: extraIndexer,
            didDecodeDocument: nil, didWriteBundle: nil
        )
    }

    /// The two hooks run off the actor once a decode has read a bundle and once `add` has written one, so a test can land work inside either.
    init(
        libraryURL: URL,
        extraIndexer: LibraryIndexer?,
        didDecodeDocument: (@Sendable () -> Void)? = nil,
        didWriteBundle: (@Sendable () -> Void)? = nil
    ) {
        self.libraryURL = libraryURL
        self.extraIndexer = extraIndexer
        self.didDecodeDocument = didDecodeDocument
        self.didWriteBundle = didWriteBundle
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
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        self.searchIndex = LibrarySearchIndex(indexURL: indexURL)
        Task { await self.ensureSearchIndexReady() }
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

    public func search(_ query: String) async -> [LibrarySearchIndex.Match] {
        await ensureSearchIndexReady()
        if cachedActive == nil { await primeCaches() }
        let activeIDs = Set((cachedActive ?? []).map(\.id))
        let matches = await searchIndex.search(query)
        return matches.filter { activeIDs.contains($0.entryID) }
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

    private func ensureSearchIndexReady() async {
        if indexReadyTask == nil {
            indexReadyTask = Task { await self.rebuildSearchIndexIfStale() }
        }
        await indexReadyTask?.value
    }

    private func rebuildSearchIndexIfStale() async {
        let url = libraryURL
        let epoch = listCacheEpoch
        let scan = await offActorIO(qos: .utility) { [self] in indexScan(at: url) }
        guard let scan else {
            indexReadyTask = nil
            return
        }
        // The list caches want the same scan; skip it if a mutation landed while it ran.
        if cachedActive == nil, epoch == listCacheEpoch { applyScan(scan.entries) }
        guard await searchIndex.needsRebuild(matching: scan.fingerprints) else { return }
        let indexable = scan.entries.filter { $0.deletedAt == nil }
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
                            notes: entry.segmentNotes, transcript: nil
                        ),
                        fingerprint: fingerprint
                    )
                }
                return .init(
                    id: entry.id,
                    title: entry.title,
                    text: doc.transcript.text,
                    auxiliaryText: Self.searchAuxiliaryText(notes: entry.segmentNotes, transcript: doc.transcript),
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
                "bundles indexed on their title alone",
                [.count: .int(rebuilt.unreadable)]
            )
        }
        await searchIndex.rebuild(entries: rebuilt.entries)
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
            let entries = await offActorIO { [self] in scanEntries(at: url) }
            if epoch == listCacheEpoch {
                applyScan(entries ?? [])
                return
            }
        }
        applyScan(scanEntries(at: url) ?? [])
    }

    private func applyScan(_ entries: [LibraryEntry]) {
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
        if doc.manifest.durationSeconds == nil, let duration = doc.transcript.durationSeconds, duration > 0 {
            try? ParolaDocument.updateManifest(at: bundleURL) { $0.durationSeconds = duration }
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

    private nonisolated static func readCleanedDocument(at bundleURL: URL) throws -> ParolaDocument {
        var doc = try ParolaDocument.read(at: bundleURL)
        // Entries written before the blank-drop moved to assembly time still carry silent VAD
        // chunks as empty rows. The surviving ids stay as they are: `segmentNotes` is keyed by them.
        doc.transcript.segments = doc.transcript.segments.droppingBlankText()
        return doc
    }

    public func add(
        transcript: Transcript,
        audioSource: URL?,
        category: EntryCategory = .transcription,
        title: String? = nil
    ) async throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        let target = bundleURL.appendingPathExtension("parola")
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
                    titleOverride: title
                )
                didWriteBundle?()
            }
        } catch is CancellationError {
            // A bundle already on disk is listed and indexed before the cancel is reported: the caches
            // are memoized, so skipping the bookkeeping would hide it until the next launch.
            guard FileManager.default.fileExists(atPath: target.path) else { throw CancellationError() }
            cancelled = true
        }
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: target)
        await indexEntry(entry, transcript: transcript)
        if cancelled { throw CancellationError() }
        return entry
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
        await ensureSearchIndexReady()
        let text = transcript.text
        await searchIndex.index(
            id: entry.id,
            title: entry.title,
            text: text,
            auxiliaryText: Self.searchAuxiliaryText(notes: entry.segmentNotes, transcript: transcript),
            boundaries: Self.segmentBoundaries(for: transcript),
            fingerprint: Self.bundleFingerprint(entry.bundleURL),
            createdAt: entry.createdAt
        )
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

    /// Where each segment lands in `Transcript.text`; a segment that trims to nothing takes the offset of the next one, so this stays indexed by segment.
    static func segmentBoundaries(for transcript: Transcript) -> [LibrarySearchIndex.SegmentBoundary] {
        var boundaries: [LibrarySearchIndex.SegmentBoundary] = []
        boundaries.reserveCapacity(transcript.segments.count)
        var offset = 0
        var joinedAny = false
        for segment in transcript.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                boundaries.append(.init(textOffset: offset + (joinedAny ? 1 : 0), seconds: segment.start))
                continue
            }
            if joinedAny { offset += 1 }
            boundaries.append(.init(textOffset: offset, seconds: segment.start))
            offset += trimmed.count
            joinedAny = true
        }
        return boundaries
    }

    /// `transcript` is nil for a bundle whose transcript is unreadable; its manifest notes still index.
    static func searchAuxiliaryText(notes: [String: String], transcript: Transcript?) -> String {
        var parts: [String] = []
        if let summary = transcript?.summary?.text, !summary.isEmpty { parts.append(summary) }
        parts.append(contentsOf: notes.sorted { $0.key < $1.key }.map(\.value))
        parts.append(contentsOf: transcript?.uniqueSpeakers ?? [])
        return parts.joined(separator: "\n")
    }

    private func deindexEntry(id: String) async {
        await ensureSearchIndexReady()
        await searchIndex.remove(id)
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
        } else {
            // transcript.json still moved, and the snapshot's fingerprint has to follow or the
            // next launch reads the newer file as a stale index and rebuilds the lot.
            await ensureSearchIndexReady()
            await searchIndex.refreshFingerprint(Self.bundleFingerprint(entry.bundleURL), for: entry.id)
        }
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

    /// Stamps the entry's `lastOpenedAt` so the library can show when it was last viewed.
    public func markOpened(id: LibraryEntry.ID, at now: Date = Date()) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.lastOpenedAt = now
        }
        try recacheEntry(at: bundleURL)
    }

    /// Re-reads the one manifest a mutation touched and folds it into the caches, so a single-entry
    /// edit doesn't force the next read to re-decode every bundle in the library.
    @discardableResult
    private func recacheEntry(at bundleURL: URL) throws -> LibraryEntry {
        do {
            let entry = try makeEntry(bundleURL: bundleURL)
            patchCaches(with: entry)
            return entry
        } catch {
            ParolaLog.error(.library, "entry recache failed, caches dropped", [.error: .error(error)])
            invalidateListCaches()
            cachedLoaded.removeAll()
            throw error
        }
    }

    private func patchCaches(with entry: LibraryEntry) {
        cachedActive = patched(cachedActive, with: entry, belongs: entry.deletedAt == nil) {
            $0.createdAt > $1.createdAt
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
        try FileManager.default.removeItem(at: bundleURL)
        removeFromCaches(id: id)
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
        return await offActorIO { Self.verifySync(at: url) }
    }

    nonisolated static func verifySync(at libraryURL: URL) -> VerificationReport {
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
            let id = (bundleURL.lastPathComponent as NSString).deletingPathExtension
            healthy.append(LibraryEntry(id: id, bundleURL: bundleURL, manifest: manifest))
        }
        return VerificationReport(healthy: healthy, problems: problems)
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
        await primeCaches()
        let toPurge = (cachedDeleted ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        var purgedIDs: [LibraryEntry.ID] = []
        var failed = 0
        var firstFailure: (any Error)?
        for entry in toPurge {
            do {
                try FileManager.default.removeItem(at: entry.bundleURL)
                cachedLoaded.remove(entry.id)
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
        }
        invalidateListCaches()
        return PurgeResult(purgedIDs: purgedIDs, failed: failed)
    }

    private func invalidateListCaches() {
        cachedActive = nil
        cachedDeleted = nil
        listCacheEpoch &+= 1
    }

    /// Drops every in-memory cache so the next read re-scans disk. The app's `--test-mode` reset
    /// wipes the library directory directly, behind this actor's back; without this the stale list
    /// cache would resurrect entries whose bundles are already gone.
    public func dropCaches() {
        cachedActive = nil
        cachedDeleted = nil
        cachedLoaded.removeAll()
        listCacheEpoch &+= 1
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
        let id = (bundleURL.lastPathComponent as NSString).deletingPathExtension
        return LibraryEntry(id: id, bundleURL: bundleURL, manifest: manifest)
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
