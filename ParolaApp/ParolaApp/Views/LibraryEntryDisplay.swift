import Foundation
import ParolaCore

enum LibraryEntryDisplay {
    static func title(for entry: LibraryEntry) -> String {
        title(raw: entry.title, createdAt: entry.createdAt)
    }

    /// The catalogue's name for the model an entry was transcribed with, falling back to the
    /// stored id for imports and models the catalogue no longer lists.
    static func modelName(raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A subtitle import ran no model, so naming the importer would read as one.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("imported-") else { return nil }
        if let captions = captionSource[trimmed] { return captions }
        return ModelCatalog.variant(id: trimmed)?.displayName ?? trimmed
    }

    /// The sentinels `YouTubeSubsFetcher` stamps when it takes a video's own captions instead of
    /// transcribing it.
    private static let captionSource: [String: String] = [
        "youtube-subs": String(localized: "YouTube subtitles"),
        "youtube-auto-subs": String(localized: "YouTube auto subtitles"),
    ]

    static func title(raw: String, createdAt: Date) -> String {
        guard isMachineName(raw) else { return raw }
        let stamp = AppFormat.dateAndTime(createdAt)
        return String(localized: "Recording — \(stamp)")
    }

    private static let machineNamePattern: NSRegularExpression = {
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        return try! NSRegularExpression(pattern: "^(parola-[a-z]+-)?\(uuid)$", options: [.caseInsensitive])
    }()

    static func isMachineName(_ title: String) -> Bool {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = base.lastIndex(of: "."), dot != base.startIndex,
           base.distance(from: base.index(after: dot), to: base.endIndex) <= 5 {
            base = String(base[..<dot])
        }
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        return machineNamePattern.firstMatch(in: base, range: range) != nil
    }
}

/// The strings a library row draws that are costly and never age, formatted once per entry snapshot.
struct LibraryRowDisplay: Identifiable {
    let entry: LibraryEntry
    let title: String
    let timestamp: String
    let timeOfDay: String
    let shortDate: String
    let sizeLabel: String?
    let durationLabel: String?
    let modelLabel: String?
    let languageLabel: String?
    let lastOpened: String?
    let tooltip: String
    /// The opening of the transcript, read from the search index. nil until the index has the entry.
    let excerpt: String?
    let sourceKind: EntrySourceKind

    var id: LibraryEntry.ID { entry.id }
    var pinned: Bool { entry.pinned }
    var noteCount: Int { entry.segmentNotes.count }
    var labels: [String] { entry.labels }

    init(entry: LibraryEntry, sizeBytes: Int64?, excerpt: String? = nil) {
        let title = LibraryEntryDisplay.title(for: entry)
        self.entry = entry
        self.title = title
        self.excerpt = excerpt
        sourceKind = EntrySourceKind(entry: entry)
        timestamp = AppFormat.dateAndTime(entry.createdAt)
        timeOfDay = AppFormat.timeOfDay(entry.createdAt)
        shortDate = AppFormat.dayAndMonth(entry.createdAt)
        if let sizeBytes, sizeBytes > 0 {
            sizeLabel = AppFormat.byteSize(sizeBytes)
        } else {
            sizeLabel = nil
        }
        durationLabel = entry.durationSeconds.flatMap { $0 > 0 ? Timecode.format($0) : nil }
        modelLabel = LibraryEntryDisplay.modelName(raw: entry.modelName)
        languageLabel = LanguageDisplay.name(for: entry.language)
        lastOpened = entry.lastOpenedAt.map { AppFormat.relativeDate($0) }

        var parts = [title, AppFormat.longDateAndTime(entry.createdAt)]
        if !entry.labels.isEmpty {
            parts.append("Labels: \(entry.labels.joined(separator: ", "))")
        }
        if entry.pinned {
            parts.append("Pinned")
        }
        tooltip = parts.joined(separator: "\n")
    }
}

/// Caches the three formatted dates a row needs, since the list rebuilds rows on every filter and sort change.
struct LibraryRowDisplayCache {
    private(set) var libraryVersion = -1
    private(set) var sizesVersion = -1
    private(set) var excerptsVersion = -1
    private(set) var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]

    mutating func invalidate(libraryVersion: Int, sizesVersion: Int, excerptsVersion: Int) {
        guard self.libraryVersion != libraryVersion
                || self.sizesVersion != sizesVersion
                || self.excerptsVersion != excerptsVersion else { return }
        displays.removeAll(keepingCapacity: true)
        self.libraryVersion = libraryVersion
        self.sizesVersion = sizesVersion
        self.excerptsVersion = excerptsVersion
    }

    mutating func display(for entry: LibraryEntry, sizeBytes: Int64?, excerpt: String? = nil) -> LibraryRowDisplay {
        if let cached = displays[entry.id] { return cached }
        let display = LibraryRowDisplay(entry: entry, sizeBytes: sizeBytes, excerpt: excerpt)
        displays[entry.id] = display
        return display
    }
}
