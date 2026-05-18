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
        let name = manifest.originalAudioName
        guard !name.isEmpty else { return "Untitled" }
        return (name as NSString).deletingPathExtension
    }

    public var createdAt: Date { manifest.createdAt }
    public var category: EntryCategory { manifest.category }
    public var deletedAt: Date? { manifest.deletedAt }
    public var updatedAt: Date? { manifest.updatedAt }
    public var labels: [String] { manifest.labels }
    public var segmentNotes: [String: String] { manifest.segmentNotes }

    public func note(forSegment id: Int) -> String? {
        manifest.segmentNotes[String(id)]
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
