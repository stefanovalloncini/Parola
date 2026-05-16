import Foundation
import ParolaCore

struct LibraryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let bundleURL: URL
    let manifest: ParolaDocument.Manifest

    var title: String {
        let name = manifest.originalAudioName
        guard !name.isEmpty else { return String(localized: "library.fallback.title") }
        return (name as NSString).deletingPathExtension
    }

    var createdAt: Date { manifest.createdAt }

    static func == (lhs: LibraryEntry, rhs: LibraryEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LoadedEntry: Sendable {
    let entry: LibraryEntry
    let document: ParolaDocument
}
