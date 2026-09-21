import Foundation

public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let bundleURL: URL
    public let manifest: ParolaDocument.Manifest

    public init(id: String, bundleURL: URL, manifest: ParolaDocument.Manifest) {
        self.id = id
        self.bundleURL = bundleURL
        self.manifest = manifest
    }

    public var title: String {
        if let title = manifest.title, !title.isEmpty { return title }
        let name = manifest.originalAudioName
        guard !name.isEmpty else { return "Untitled" }
        return (name as NSString).deletingPathExtension
    }

    public var createdAt: Date { manifest.createdAt }
    public var category: EntryCategory { manifest.category }
    public var deletedAt: Date? { manifest.deletedAt }
    public var updatedAt: Date? { manifest.updatedAt }
    public var lastOpenedAt: Date? { manifest.lastOpenedAt }
    public var labels: [String] { manifest.labels }
    public var segmentNotes: [String: String] { manifest.segmentNotes }
    public var favoriteSegments: Set<Int> { Set(manifest.favoriteSegments) }
    public var pinned: Bool { manifest.pinned }
    public var durationSeconds: Double? { manifest.durationSeconds }
    public var language: String { manifest.language }
    public var modelName: String { manifest.modelName }
    public var sourceDigest: String? { manifest.sourceDigest }
    public var transcriptionSeconds: Double? { manifest.transcriptionSeconds }
    public var wordCount: Int? { manifest.wordCount }
    public var aiTitle: String? { manifest.aiTitle }
    public var shortSummary: String? { manifest.shortSummary }

    public func note(forSegment id: Int) -> String? {
        manifest.segmentNotes[String(id)]
    }

    public func isFavorite(segment id: Int) -> Bool {
        manifest.favoriteSegments.contains(id)
    }

    public static func == (lhs: LibraryEntry, rhs: LibraryEntry) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct LoadedEntry: Sendable {
    public let entry: LibraryEntry
    public let document: ParolaDocument

    public init(entry: LibraryEntry, document: ParolaDocument) {
        self.entry = entry
        self.document = document
    }
}
