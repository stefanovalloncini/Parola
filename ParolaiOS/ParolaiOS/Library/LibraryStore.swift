import Foundation
import ParolaCore

actor LibraryStore {
    enum LibraryError: Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return String(localized: "library.notfound")
            }
        }
    }

    static let shared = LibraryStore()
    static var defaultLibraryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Library", directoryHint: .isDirectory)
    }

    let libraryURL: URL
    private var cachedActive: [LibraryEntry]?
    private var cachedDeleted: [LibraryEntry]?
    private var cachedLoaded: (id: LibraryEntry.ID, value: LoadedEntry)?

    init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.libraryURL = libraryURL
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        var url = libraryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? url.setResourceValues(values)
    }

    func list() -> [LibraryEntry] {
        if let cachedActive { return cachedActive }
        primeCaches()
        return cachedActive ?? []
    }

    func listDeleted() -> [LibraryEntry] {
        if let cachedDeleted { return cachedDeleted }
        primeCaches()
        return cachedDeleted ?? []
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

    func load(_ id: LibraryEntry.ID) throws -> LoadedEntry {
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

    func add(transcript: Transcript, audioSource: URL?) throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        try ParolaDocument.write(
            transcript: transcript,
            audioURL: audioSource,
            to: bundleURL
        )
        invalidateListCaches()
        return try makeEntry(bundleURL: bundleURL.appendingPathExtension("parola"))
    }

    func adopt(parolaBundle url: URL) throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let target = libraryURL.appendingPathComponent("\(name).parola")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: url, to: target)
        invalidateListCaches()
        return try makeEntry(bundleURL: target)
    }

    /// Soft-deletes by stamping `deletedAt`. The bundle stays on disk so it can be restored.
    func delete(_ id: LibraryEntry.ID, at now: Date = Date()) throws {
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
    func restore(_ id: LibraryEntry.ID) throws {
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
    func purge(_ id: LibraryEntry.ID) throws {
        let bundleURL = libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LibraryError.notFound(id)
        }
        try FileManager.default.removeItem(at: bundleURL)
        invalidateListCaches()
        if cachedLoaded?.id == id { cachedLoaded = nil }
    }

    /// Hard-deletes any soft-deleted entry whose `deletedAt` is older than `days` before `now`.
    func purgeDeletedOlderThan(days: Int, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        primeCaches()
        let toPurge = (cachedDeleted ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        for entry in toPurge {
            try? FileManager.default.removeItem(at: entry.bundleURL)
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
