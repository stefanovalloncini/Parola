import Foundation
import ParolaCore

enum LibraryEntryDisplay {
    static func title(for entry: LibraryEntry) -> String {
        let stored = entry.manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title(raw: entry.title, createdAt: entry.createdAt, fromFileName: stored.isEmpty)
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

    /// For an entry whose source was a link: the fetcher hands back a working file, never the video's own name.
    static func webVideoTitle(createdAt: Date) -> String {
        let stamp = AppFormat.dateAndTime(createdAt)
        return String(localized: "Web video — \(stamp)")
    }

    /// `fromFileName: false` marks a title the user typed, which stands even when it reads as a generic word.
    static func title(raw: String, createdAt: Date, fromFileName: Bool = true) -> String {
        guard isMachineName(raw) || (fromFileName && isGenericName(raw)) else { return raw }
        let stamp = AppFormat.dateAndTime(createdAt)
        return String(localized: "Recording — \(stamp)")
    }

    private static let machineNamePattern: NSRegularExpression = {
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        return try! NSRegularExpression(pattern: "^(parola-[a-z]+-)?\(uuid)$", options: [.caseInsensitive])
    }()

    /// The names a working file carries — a YouTube download and a bundle's own copy are both `audio.<ext>`.
    private static let genericNames: Set<String> = [
        "audio", "recording", "output", "media", "sound", "file", "temp", "tmp",
    ]

    static func isPlaceholderName(_ title: String) -> Bool {
        isMachineName(title) || isGenericName(title)
    }

    static func isGenericName(_ title: String) -> Bool {
        genericNames.contains(baseName(title).lowercased())
    }

    static func isMachineName(_ title: String) -> Bool {
        let base = baseName(title)
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        return machineNamePattern.firstMatch(in: base, range: range) != nil
    }

    private static func baseName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex,
              trimmed.distance(from: trimmed.index(after: dot), to: trimmed.endIndex) <= 5
        else { return trimmed }
        return String(trimmed[..<dot])
    }
}

/// The strings a library row draws that are costly and never age, formatted once per entry snapshot.
struct LibraryRowDisplay: Identifiable {
    let entry: LibraryEntry
    let title: String
    let timeOfDay: String
    let shortDate: String
    let durationLabel: String?
    let modelLabel: String?
    let languageLabel: String?
    let tooltip: String
    /// The opening of the transcript, read from the search index. nil until the index has the entry.
    /// Replaced by the entry's AI summary when `showsAISummary` is set.
    let excerpt: String?
    /// The excerpt argument as passed in, before any AI-summary substitution — what the cache compares against.
    let rawExcerpt: String?
    let sourceKind: EntrySourceKind

    var id: LibraryEntry.ID { entry.id }
    var pinned: Bool { entry.pinned }
    var noteCount: Int { entry.segmentNotes.count }
    var labels: [String] { entry.labels }

    /// `date` is what the row states; `dateLabel` names it where the bare day would read as the creation.
    /// `showsAITitle`/`showsAISummary` swap in the entry's generated title and summary when it has one.
    init(
        entry: LibraryEntry,
        excerpt: String? = nil,
        date: Date? = nil,
        dateLabel: String? = nil,
        showsAITitle: Bool = false,
        showsAISummary: Bool = false
    ) {
        let baseTitle = LibraryEntryDisplay.title(for: entry)
        let title = showsAITitle ? (entry.aiTitle ?? baseTitle) : baseTitle
        let stated = date ?? entry.createdAt
        self.entry = entry
        self.title = title
        self.excerpt = showsAISummary ? (entry.shortSummary ?? excerpt) : excerpt
        self.rawExcerpt = excerpt
        sourceKind = EntrySourceKind(entry: entry)
        timeOfDay = dateLabel ?? AppFormat.timeOfDay(stated)
        shortDate = dateLabel ?? AppFormat.dayAndMonth(stated)
        durationLabel = entry.durationSeconds.flatMap { $0 > 0 ? Timecode.format($0) : nil }
        modelLabel = LibraryEntryDisplay.modelName(raw: entry.modelName)
        languageLabel = LanguageDisplay.name(for: entry.language)

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

/// Caches the strings a row needs, since the list rebuilds rows on every filter and sort change.
struct LibraryRowDisplayCache {
    private(set) var libraryVersion = -1
    private(set) var excerptsVersion = -1
    private(set) var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]

    mutating func invalidate(libraryVersion: Int, excerptsVersion: Int) {
        guard self.libraryVersion != libraryVersion || self.excerptsVersion != excerptsVersion else { return }
        displays.removeAll(keepingCapacity: true)
        self.libraryVersion = libraryVersion
        self.excerptsVersion = excerptsVersion
    }

    mutating func display(
        for entry: LibraryEntry,
        excerpt: String? = nil,
        date: Date? = nil,
        dateLabel: String? = nil,
        showsAITitle: Bool = false,
        showsAISummary: Bool = false
    ) -> LibraryRowDisplay {
        if let cached = displays[entry.id], cached.rawExcerpt == excerpt { return cached }
        let display = LibraryRowDisplay(
            entry: entry, excerpt: excerpt, date: date, dateLabel: dateLabel,
            showsAITitle: showsAITitle, showsAISummary: showsAISummary
        )
        displays[entry.id] = display
        return display
    }
}
