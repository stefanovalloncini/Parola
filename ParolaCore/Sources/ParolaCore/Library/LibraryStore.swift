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

    public init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.init(libraryURL: libraryURL, extraIndexer: SpotlightIndexer())
    }

    public init(libraryURL: URL, extraIndexer: LibraryIndexer?) {
        self.libraryURL = libraryURL
        self.extraIndexer = extraIndexer
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        self.searchIndex = LibrarySearchIndex(indexURL: indexURL)
        Task { await self.ensureSearchIndexReady() }
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
        let rebuilt = await Task.detached(priority: .utility) { [self] in
            scanEntries(at: url).compactMap { entry -> LibrarySearchIndex.RebuildEntry? in
                guard let doc = try? ParolaDocument.read(at: entry.bundleURL) else { return nil }
                return .init(
                    id: entry.id,
                    title: entry.title,
                    text: doc.transcript.text,
                    auxiliaryText: Self.searchAuxiliaryText(notes: entry.segmentNotes, transcript: doc.transcript)
                )
            }
        }.value
        await searchIndex.rebuild(entries: rebuilt)
    }

    private func primeCaches() async {
        let url = libraryURL
        let epoch = listCacheEpoch
        let entries = await Task.detached(priority: .userInitiated) { [self] in
            scanEntries(at: url)
        }.value
        // The scan is an await, so a mutation can invalidate the caches mid-scan. Caching this snapshot
        // would then resurrect the pre-mutation state for the next reader (e.g. an un-renamed title), so
        // skip the cache when the epoch moved; the next read re-scans.
        guard epoch == listCacheEpoch else { return }
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
        // Detached: writing the bundle copies the source media, which can take seconds for long
        // recordings and would stall every other library call on this actor.
        try await Task.detached(priority: .userInitiated) {
            _ = try ParolaDocument.write(
                transcript: transcript,
                audioURL: audioSource,
                to: bundleURL,
                category: category,
                titleOverride: title
            )
        }.value
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
            // Detached: bundle copies can be multi-GB and would stall every other library call.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: staging)
                try FileManager.default.moveItem(at: staging, to: target)
            }.value
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
        await extraIndexer.index(id: entry.id, title: entry.title, text: text, createdAt: entry.createdAt)
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
        await extraIndexer.deindex(id: id)
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transcript)
        try data.write(to: transcriptURL, options: .atomic)
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.updatedAt = now
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
        if reindex {
            let entry = try makeEntry(bundleURL: bundleURL)
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
        let entry = try makeEntry(bundleURL: bundleURL)
        if let doc = try? ParolaDocument.read(at: bundleURL) {
            await indexEntry(entry, transcript: doc.transcript)
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
        let entry = try makeEntry(bundleURL: bundleURL)
        if let doc = try? ParolaDocument.read(at: bundleURL) {
            await indexEntry(entry, transcript: doc.transcript)
        }
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
        // lastOpenedAt changes no list membership or ordering; patch caches in place so opening
        // an entry doesn't force a full rescan and a disk reload of the document it just cached.
        patchCaches(with: try makeEntry(bundleURL: bundleURL))
    }

    private func patchCaches(with entry: LibraryEntry) {
        if let i = cachedActive?.firstIndex(where: { $0.id == entry.id }) { cachedActive?[i] = entry }
        if let i = cachedDeleted?.firstIndex(where: { $0.id == entry.id }) { cachedDeleted?[i] = entry }
        if let cached = cachedLoaded, cached.id == entry.id {
            cachedLoaded = (entry.id, LoadedEntry(entry: entry, document: cached.value.document))
        }
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
        if let entry = try? makeEntry(bundleURL: bundleURL),
           let doc = try? ParolaDocument.read(at: bundleURL) {
            await indexEntry(entry, transcript: doc.transcript)
        }
    }

    /// Permanently removes a bundle from disk.
    public func purge(_ id: LibraryEntry.ID) async throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try FileManager.default.removeItem(at: bundleURL)
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
        return await Task.detached(priority: .userInitiated) {
            Self.verifySync(at: url)
        }.value
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
