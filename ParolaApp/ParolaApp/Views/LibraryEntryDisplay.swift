import Foundation
import ParolaCore

enum LibraryEntryDisplay {
    static func title(for entry: LibraryEntry) -> String {
        let stored = entry.manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title(raw: entry.title, createdAt: entry.createdAt, fromFileName: stored.isEmpty)
    }

    /// A title with no recorded source loses to the AI one, so a generated stamp never outranks it.
    static func listTitle(for entry: LibraryEntry, showsAITitle: Bool) -> String {
        if let real = realTitle(for: entry) { return real }
        if showsAITitle, let aiTitle = entry.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !aiTitle.isEmpty {
            return aiTitle
        }
        return title(for: entry)
    }

    /// nil unless the stored title is known real (typed by the user, or read from the source itself).
    private static func realTitle(for entry: LibraryEntry) -> String? {
        guard entry.manifest.titleSource != nil else { return nil }
        let stored = entry.manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stored.isEmpty, !isMachineName(stored) else { return nil }
        return stored
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

/// The strings a library row draws, formatted once per entry snapshot and kept while they still read true.
struct LibraryRowDisplay: Identifiable, Equatable {
    let entry: LibraryEntry
    let title: String
    let when: String
    let duration: String?
    let spokenDuration: String?
    /// Named only when it isn't the library's usual language.
    let language: String?
    /// The usual language as passed in — what the cache compares against.
    let usualLanguage: String?
    let tooltip: String
    /// The opening of the transcript, read from the search index. nil until the index has the entry.
    /// Replaced by the entry's AI summary when `showsAISummary` is set.
    let excerpt: String?
    /// The excerpt argument as passed in, before any AI-summary substitution — what the cache compares against.
    let rawExcerpt: String?
    let showsAITitle: Bool
    let showsAISummary: Bool
    let sourceKind: EntrySourceKind

    var id: LibraryEntry.ID { entry.id }
    var pinned: Bool { entry.pinned }
    var noteCount: Int { entry.segmentNotes.count }
    var labels: [String] { entry.labels }

    /// `LibraryEntry` compares by id, so its manifest is compared here: the note chip and the row's menu read it.
    static func == (lhs: LibraryRowDisplay, rhs: LibraryRowDisplay) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.entry.bundleURL == rhs.entry.bundleURL
            && lhs.entry.manifest == rhs.entry.manifest
            && lhs.title == rhs.title
            && lhs.when == rhs.when
            && lhs.duration == rhs.duration
            && lhs.spokenDuration == rhs.spokenDuration
            && lhs.language == rhs.language
            && lhs.tooltip == rhs.tooltip
            && lhs.excerpt == rhs.excerpt
            && lhs.rawExcerpt == rhs.rawExcerpt
            && lhs.showsAITitle == rhs.showsAITitle
            && lhs.showsAISummary == rhs.showsAISummary
            && lhs.sourceKind == rhs.sourceKind
    }

    /// A nil `when` states the creation day with no header over the row. `usualLanguage` is the library's, as a code.
    /// `showsAITitle`/`showsAISummary` swap in the entry's generated title and summary when it has one.
    init(
        entry: LibraryEntry,
        excerpt: String? = nil,
        when: String? = nil,
        usualLanguage: String? = nil,
        showsAITitle: Bool = false,
        showsAISummary: Bool = false
    ) {
        let title = LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showsAITitle)
        self.entry = entry
        self.title = title
        self.when = when ?? LibraryRowFormat.when(entry.createdAt, under: nil)
        duration = LibraryRowFormat.duration(entry.durationSeconds)
        spokenDuration = LibraryRowFormat.spokenDuration(entry.durationSeconds)
        self.usualLanguage = usualLanguage
        language = LanguageDisplay.code(for: entry.language) == usualLanguage
            ? nil
            : LanguageDisplay.name(for: entry.language)
        self.excerpt = showsAISummary ? (entry.shortSummary ?? excerpt) : excerpt
        self.rawExcerpt = excerpt
        self.showsAITitle = showsAITitle
        self.showsAISummary = showsAISummary
        sourceKind = EntrySourceKind(entry: entry)

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
    private(set) var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]
    private var formatting = LibraryRowDisplayCache.currentFormatting

    /// What the strings were written under besides the entry: locale, time zone and 12/24-hour clock.
    static var currentFormatting: String {
        let locale = AppFormat.locale
        return "\(locale.identifier)|\(TimeZone.current.identifier)|\(locale.hourCycle)"
    }

    /// Drops everything written under other formatting, then the entries that left the kept set.
    /// The rest stay, since `display(for:)` checks each row itself.
    mutating func prune(
        keeping ids: some Collection<LibraryEntry.ID>,
        formatting current: String = LibraryRowDisplayCache.currentFormatting
    ) {
        if formatting != current {
            formatting = current
            displays.removeAll()
        }
        guard !displays.isEmpty else { return }
        let live = Set(ids)
        displays = displays.filter { live.contains($0.key) }
    }

    /// For the one input no entry carries: the locale and clock format every row was written with.
    mutating func removeAll() {
        displays.removeAll(keepingCapacity: true)
    }

    /// The time is part of the hit test: the same entry reads differently under another header or on another day.
    mutating func display(
        for entry: LibraryEntry,
        excerpt: String? = nil,
        when: String? = nil,
        usualLanguage: String? = nil,
        showsAITitle: Bool = false,
        showsAISummary: Bool = false
    ) -> LibraryRowDisplay {
        let when = when ?? LibraryRowFormat.when(entry.createdAt, under: nil)
        if let cached = displays[entry.id],
           cached.when == when,
           cached.usualLanguage == usualLanguage,
           cached.rawExcerpt == excerpt,
           cached.showsAITitle == showsAITitle,
           cached.showsAISummary == showsAISummary,
           cached.entry.manifest == entry.manifest {
            return cached
        }
        let display = LibraryRowDisplay(
            entry: entry, excerpt: excerpt, when: when, usualLanguage: usualLanguage,
            showsAITitle: showsAITitle, showsAISummary: showsAISummary
        )
        displays[entry.id] = display
        return display
    }
}
