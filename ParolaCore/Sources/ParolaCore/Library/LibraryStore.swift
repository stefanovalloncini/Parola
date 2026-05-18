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

    public init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.init(libraryURL: libraryURL, extraIndexer: SpotlightIndexer())
    }

    public init(libraryURL: URL, extraIndexer: LibraryIndexer?) {
        self.libraryURL = libraryURL
        self.extraIndexer = extraIndexer
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        self.searchIndex = LibrarySearchIndex(indexURL: indexURL)
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
        if cachedActive == nil { await primeCaches() }
        let activeIDs = Set((cachedActive ?? []).map(\.id))
        let matches = await searchIndex.search(query)
        return matches.filter { activeIDs.contains($0.entryID) }
    }

    private func primeCaches() async {
        let url = libraryURL
        let entries = await Task.detached(priority: .userInitiated) { [self] in
            scanEntries(at: url)
        }.value
        let active = entries
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        let deleted = entries
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        cachedActive = active
        cachedDeleted = deleted
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
        try ParolaDocument.write(
            transcript: transcript,
            audioURL: audioSource,
            to: bundleURL,
            category: category,
            titleOverride: title
        )
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: bundleURL.appendingPathExtension("parola"))
        await indexEntry(entry, transcriptText: transcript.text)
        return entry
    }

    public func adopt(parolaBundle url: URL) async throws -> LibraryEntry {
        let sourceDoc = try ParolaDocument.read(at: url)
        let name = uniqueEntryName(at: Date())
        let target = libraryURL.appendingPathComponent("\(name).parola")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        do {
            try fm.copyItem(at: url, to: target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: target)
        await indexEntry(entry, transcriptText: sourceDoc.transcript.text)
        return entry
    }

    private func indexEntry(_ entry: LibraryEntry, transcriptText: String) async {
        await searchIndex.index(id: entry.id, title: entry.title, text: transcriptText, createdAt: entry.createdAt)
        guard let extraIndexer else { return }
        let id = entry.id
        let title = entry.title
        let createdAt = entry.createdAt
        Task.detached(priority: .utility) {
            await extraIndexer.index(id: id, title: title, text: transcriptText, createdAt: createdAt)
        }
    }

    private func deindexEntry(id: String) async {
        await searchIndex.remove(id)
        guard let extraIndexer else { return }
        Task.detached(priority: .utility) {
            await extraIndexer.deindex(id: id)
        }
    }

    /// Overwrites the transcript.json inside an existing bundle. Bumps the manifest `updatedAt`.
    public func updateTranscript(_ transcript: Transcript, for id: LibraryEntry.ID, at now: Date = Date()) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transcript)
        try data.write(to: transcriptURL, options: .atomic)
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.updatedAt = now
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
    }

    /// Renames an entry's display title by updating the manifest's `originalAudioName`.
    public func renameEntry(_ id: LibraryEntry.ID, to newName: String) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            let existingExtension = (manifest.originalAudioName as NSString).pathExtension
            if existingExtension.isEmpty || trimmed.contains(".") {
                manifest.originalAudioName = trimmed
            } else {
                manifest.originalAudioName = "\(trimmed).\(existingExtension)"
            }
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
    }

    /// Sets a note for a segment within an entry. Pass `nil` or empty to clear it.
    public func setSegmentNote(_ note: String?, segmentID: Int, for id: LibraryEntry.ID) throws {
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
    }

    /// Replaces the labels on a library entry. Empty array clears them.
    public func setLabels(_ labels: [String], for id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.labels = labels.compactMap { name -> String? in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
    }

    /// Soft-deletes by stamping `deletedAt`. The bundle stays on disk so it can be restored.
    public func delete(_ id: LibraryEntry.ID, at now: Date = Date()) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.deletedAt = now
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
    }

    /// Reverses a soft-delete by clearing `deletedAt`.
    public func restore(_ id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try ParolaDocument.updateManifest(at: bundleURL) { manifest in
            manifest.deletedAt = nil
        }
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
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
    }

    private nonisolated func makeEntry(bundleURL: URL) throws -> LibraryEntry {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: data)
        let id = (bundleURL.lastPathComponent as NSString).deletingPathExtension
        return LibraryEntry(id: id, bundleURL: bundleURL, manifest: manifest)
    }

    private func uniqueEntryName(at date: Date) -> String {
        let prefix = isoBasic(date)
        let short = String(UUID().uuidString.prefix(8)).lowercased()
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
