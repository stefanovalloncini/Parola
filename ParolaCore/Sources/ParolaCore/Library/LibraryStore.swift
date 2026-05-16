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
        var url = libraryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? url.setResourceValues(values)
        let indexURL = libraryURL.appendingPathComponent(".search-index.json")
        self.searchIndex = LibrarySearchIndex(indexURL: indexURL)
    }

    public func list() -> [LibraryEntry] {
        if let cachedActive { return cachedActive }
        primeCaches()
        return cachedActive ?? []
    }

    public func listDeleted() -> [LibraryEntry] {
        if let cachedDeleted { return cachedDeleted }
        primeCaches()
        return cachedDeleted ?? []
    }

    public func search(_ query: String) async -> [LibrarySearchIndex.Match] {
        let matches = await searchIndex.search(query)
        if cachedActive == nil { primeCaches() }
        let activeIDs = Set((cachedActive ?? []).map(\.id))
        return matches.filter { activeIDs.contains($0.entryID) }
    }

    private func primeCaches() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else {
            cachedActive = []
            cachedDeleted = []
            return
        }
        let all = contents
            .filter { $0.pathExtension == "parola" }
            .compactMap { try? makeEntry(bundleURL: $0) }
            .sorted { $0.createdAt > $1.createdAt }
        cachedActive = all.filter { $0.deletedAt == nil }
        cachedDeleted = all
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
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

    public func add(transcript: Transcript, audioSource: URL?) async throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        try ParolaDocument.write(
            transcript: transcript,
            audioURL: audioSource,
            to: bundleURL
        )
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: bundleURL.appendingPathExtension("parola"))
        await searchIndex.index(id: entry.id, title: entry.title, text: transcript.text, createdAt: entry.createdAt)
        if let extraIndexer {
            await extraIndexer.index(id: entry.id, title: entry.title, text: transcript.text, createdAt: entry.createdAt)
        }
        return entry
    }

    public func adopt(parolaBundle url: URL) async throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let target = libraryURL.appendingPathComponent("\(name).parola")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: url, to: target)
        invalidateListCaches()
        let entry = try makeEntry(bundleURL: target)
        let doc = try ParolaDocument.read(at: target)
        await searchIndex.index(id: entry.id, title: entry.title, text: doc.transcript.text, createdAt: entry.createdAt)
        if let extraIndexer {
            await extraIndexer.index(id: entry.id, title: entry.title, text: doc.transcript.text, createdAt: entry.createdAt)
        }
        return entry
    }

    /// Overwrites the transcript.json inside an existing bundle. Audio + manifest untouched.
    public func updateTranscript(_ transcript: Transcript, for id: LibraryEntry.ID) throws {
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
        await searchIndex.remove(id)
        if let extraIndexer { await extraIndexer.deindex(id: id) }
    }

    /// Hard-deletes any soft-deleted entry whose `deletedAt` is older than `days` before `now`.
    public func purgeDeletedOlderThan(days: Int, now: Date) async {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        primeCaches()
        let toPurge = (cachedDeleted ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        for entry in toPurge {
            try? FileManager.default.removeItem(at: entry.bundleURL)
            await searchIndex.remove(entry.id)
            if let extraIndexer { await extraIndexer.deindex(id: entry.id) }
        }
        invalidateListCaches()
    }

    private func invalidateListCaches() {
        cachedActive = nil
        cachedDeleted = nil
    }

    private func makeEntry(bundleURL: URL) throws -> LibraryEntry {
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
