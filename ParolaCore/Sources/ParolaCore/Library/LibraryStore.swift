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

    public static let shared = LibraryStore()
    public static var defaultLibraryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Library", directoryHint: .isDirectory)
    }

    public nonisolated let libraryURL: URL
    private let searchIndex: LibrarySearchIndex
    private let extraIndexer: LibraryIndexer?
    private var cachedActive: [LibraryEntry]?
    private var cachedDeleted: [LibraryEntry]?
    private var cachedLoaded: (id: LibraryEntry.ID, value: LoadedEntry)?
    private var listCacheEpoch = 0
    private var indexReadyTask: Task<Void, Never>?
    private nonisolated let extraIndexerJobs: AsyncStream<@Sendable () async -> Void>.Continuation?

    public init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.init(libraryURL: libraryURL, extraIndexer: SpotlightIndexer())
    }

    public init(libraryURL: URL, extraIndexer: LibraryIndexer?) {
        self.libraryURL = libraryURL
        self.extraIndexer = extraIndexer
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

    private func ensureSearchIndexReady() async {
        if indexReadyTask == nil {
            indexReadyTask = Task { await self.rebuildSearchIndexIfStale() }
        }
        await indexReadyTask?.value
    }

    private func rebuildSearchIndexIfStale() async {
        guard await searchIndex.needsRebuild() else { return }
        let url = libraryURL
        let rebuilt = await offActorIO(qos: .utility) { [self] in
            scanEntries(at: url).compactMap { entry -> LibrarySearchIndex.RebuildEntry? in
                guard let doc = try? ParolaDocument.read(at: entry.bundleURL) else { return nil }
                return .init(
                    id: entry.id,
                    title: entry.title,
                    text: doc.transcript.text,
                    auxiliaryText: Self.searchAuxiliaryText(notes: entry.segmentNotes, transcript: doc.transcript)
                )
            }
        }
        await searchIndex.rebuild(entries: rebuilt)
    }

    private func primeCaches() async {
        let url = libraryURL
        // The scan is an await, so a mutation can invalidate the caches mid-scan. Caching that snapshot
        // would resurrect the pre-mutation state for the next reader (e.g. an un-renamed title), so retry
        // under the new epoch; the on-actor last resort can't be interleaved at all.
        for _ in 0..<3 {
            let epoch = listCacheEpoch
            let entries = await offActorIO { [self] in scanEntries(at: url) }
            if epoch == listCacheEpoch {
                applyScan(entries)
                return
            }
        }
        applyScan(scanEntries(at: url))
    }

    private func applyScan(_ entries: [LibraryEntry]) {
        cachedActive = entries
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        cachedDeleted = entries
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private nonisolated func scanEntries(at libraryURL: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "parola" }
            .compactMap { try? makeEntry(bundleURL: $0) }
    }

    public func load(_ id: LibraryEntry.ID) throws -> LoadedEntry {
        if let cached = cachedLoaded, cached.id == id {
            return cached.value
        }
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let doc = try ParolaDocument.read(at: bundleURL)
        let entry = try makeEntry(bundleURL: bundleURL)
        let loaded = LoadedEntry(entry: entry, document: doc)
        cachedLoaded = (id, loaded)
        return loaded
    }

    public func add(
        transcript: Transcript,
        audioSource: URL?,
        category: EntryCategory = .transcription,
        title: String? = nil
    ) async throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        // Off the actor: writing the bundle copies the source media, which can take seconds for long
        // recordings and would stall every other library call on this actor.
        try await offActorThrowingIO {
            _ = try ParolaDocument.write(
                transcript: transcript,
                audioURL: audioSource,
                to: bundleURL,
                category: category,
                titleOverride: title
            )
        }
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: bundleURL.appendingPathExtension("parola"))
        await indexEntry(entry, transcript: transcript)
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

    static func searchAuxiliaryText(notes: [String: String], transcript: Transcript) -> String {
        var parts: [String] = []
        if let summary = transcript.summary?.text, !summary.isEmpty { parts.append(summary) }
        parts.append(contentsOf: notes.sorted { $0.key < $1.key }.map(\.value))
        parts.append(contentsOf: transcript.uniqueSpeakers)
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
        if cachedLoaded?.id == id { cachedLoaded = nil }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(transcript)
            try data.write(to: transcriptURL, options: .atomic)
            try ParolaDocument.updateManifest(at: bundleURL) { manifest in
                manifest.updatedAt = now
            }
        } catch {
            // transcript.json lands before the manifest, so a throw in between puts disk ahead of memory.
            invalidateListCaches()
            throw error
        }
        let entry = try recacheEntry(at: bundleURL)
        if reindex {
            await indexEntry(entry, transcript: transcript)
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
        if let cached = cachedLoaded, cached.id == id { return cached.value.document.transcript }
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
            invalidateListCaches()
            cachedLoaded = nil
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
        if let cached = cachedLoaded, cached.id == entry.id {
            cachedLoaded = (entry.id, LoadedEntry(entry: entry, document: cached.value.document))
        }
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
        if cachedLoaded?.id == id { cachedLoaded = nil }
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

    /// Hard-deletes any soft-deleted entry whose `deletedAt` is older than `days` before `now`.
    public func purgeDeletedOlderThan(days: Int, now: Date) async {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        await primeCaches()
        let toPurge = (cachedDeleted ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        for entry in toPurge {
            do {
                try FileManager.default.removeItem(at: entry.bundleURL)
                await deindexEntry(id: entry.id)
            } catch {
                continue
            }
        }
        invalidateListCaches()
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
        cachedLoaded = nil
        listCacheEpoch &+= 1
    }

    private nonisolated func makeEntry(bundleURL: URL) throws -> LibraryEntry {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: data)
        guard manifest.version <= ParolaDocument.Manifest.currentVersion else {
            throw ParolaError.ioError("Parola document version \(manifest.version) is newer than this app understands.")
        }
        let id = (bundleURL.lastPathComponent as NSString).deletingPathExtension
        return LibraryEntry(id: id, bundleURL: bundleURL, manifest: manifest)
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

/// Continuation + GCD, not `Task.detached`: a detached job resuming actor work around the
/// NSURL-bridging Foundation calls above has crashed with EXC_ARM_DA_ALIGN before (same class as
/// the watched-folder bookmark and duration-probe fixes).
private func offActorIO<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}

private func offActorThrowingIO<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try work() }) }
    }
}
