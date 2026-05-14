import Foundation
import ParolaCore

actor LibraryStore {
    enum LibraryError: Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let id): return "Library entry \(id) not found."
            }
        }
    }

    static let shared = LibraryStore()
    static var defaultLibraryURL: URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Parola/Library", isDirectory: true)
    }

    let libraryURL: URL

    init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        self.libraryURL = libraryURL
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        var url = libraryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? url.setResourceValues(values)
    }

    func list() -> [LibraryEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "parola" }
            .compactMap { try? makeEntry(bundleURL: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func load(_ id: LibraryEntry.ID) throws -> LoadedEntry {
        guard let entry = list().first(where: { $0.id == id }) else {
            throw LibraryError.notFound(id)
        }
        let doc = try ParolaDocument.read(at: entry.bundleURL)
        return LoadedEntry(entry: entry, document: doc)
    }

    func add(transcript: Transcript, audioSource: URL) throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let bundleURL = libraryURL.appendingPathComponent(name)
        try ParolaDocument.write(
            transcript: transcript,
            audioURL: audioSource,
            to: bundleURL
        )
        return try makeEntry(bundleURL: bundleURL.appendingPathExtension("parola"))
    }

    func adopt(parolaBundle url: URL) throws -> LibraryEntry {
        let name = uniqueEntryName(at: Date())
        let target = libraryURL.appendingPathComponent("\(name).parola")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: url, to: target)
        return try makeEntry(bundleURL: target)
    }

    func delete(_ id: LibraryEntry.ID) throws {
        guard let entry = list().first(where: { $0.id == id }) else {
            throw LibraryError.notFound(id)
        }
        try FileManager.default.removeItem(at: entry.bundleURL)
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
