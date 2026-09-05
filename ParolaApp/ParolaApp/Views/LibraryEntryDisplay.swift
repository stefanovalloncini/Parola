import Foundation
import ParolaCore

enum LibraryEntryDisplay {
    static func title(for entry: LibraryEntry) -> String {
        title(raw: entry.title, createdAt: entry.createdAt)
    }

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
    let sizeLabel: String?
    let durationLabel: String?
    let languageLabel: String?
    let lastOpened: String?
    let tooltip: String

    var id: LibraryEntry.ID { entry.id }
    var pinned: Bool { entry.pinned }
    var noteCount: Int { entry.segmentNotes.count }

    init(entry: LibraryEntry, sizeBytes: Int64?) {
        let title = LibraryEntryDisplay.title(for: entry)
        self.entry = entry
        self.title = title
        timestamp = AppFormat.dateAndTime(entry.createdAt)
        if let sizeBytes, sizeBytes > 0 {
            sizeLabel = AppFormat.byteSize(sizeBytes)
        } else {
            sizeLabel = nil
        }
        durationLabel = entry.durationSeconds.flatMap { $0 > 0 ? Timecode.format($0) : nil }
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

/// Building a display formats three dates, and the list rebuilds its rows on every filter, sort and category
/// change. The entries only change with the library version, so displays are kept until one of those moves.
struct LibraryRowDisplayCache {
    private(set) var libraryVersion = -1
    private(set) var sizesVersion = -1
    private(set) var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]

    mutating func invalidate(libraryVersion: Int, sizesVersion: Int) {
        guard self.libraryVersion != libraryVersion || self.sizesVersion != sizesVersion else { return }
        displays.removeAll(keepingCapacity: true)
        self.libraryVersion = libraryVersion
        self.sizesVersion = sizesVersion
    }

    mutating func display(for entry: LibraryEntry, sizeBytes: Int64?) -> LibraryRowDisplay {
        if let cached = displays[entry.id] { return cached }
        let display = LibraryRowDisplay(entry: entry, sizeBytes: sizeBytes)
        displays[entry.id] = display
        return display
    }
}
