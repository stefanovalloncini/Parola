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
/// The relative and hover strings stay lazy so only the rows actually on screen pay for them.
struct LibraryRowDisplay: Identifiable {
    let entry: LibraryEntry
    let title: String
    let timestamp: String
    let sizeLabel: String?
    let durationLabel: String?
    let languageLabel: String?

    var id: LibraryEntry.ID { entry.id }
    var pinned: Bool { entry.pinned }
    var noteCount: Int { entry.segmentNotes.count }
    var lastOpened: String? { entry.lastOpenedAt?.formatted(.relative(presentation: .named)) }

    var tooltip: String {
        var parts = [title, AppFormat.longDateAndTime(entry.createdAt)]
        if !entry.labels.isEmpty {
            parts.append("Labels: \(entry.labels.joined(separator: ", "))")
        }
        if entry.pinned {
            parts.append("Pinned")
        }
        return parts.joined(separator: "\n")
    }

    init(entry: LibraryEntry, sizeBytes: Int64?) {
        self.entry = entry
        title = LibraryEntryDisplay.title(for: entry)
        timestamp = AppFormat.dateAndTime(entry.createdAt)
        if let sizeBytes, sizeBytes > 0 {
            sizeLabel = AppFormat.byteSize(sizeBytes)
        } else {
            sizeLabel = nil
        }
        durationLabel = entry.durationSeconds.flatMap { $0 > 0 ? Timecode.format($0) : nil }
        languageLabel = LanguageDisplay.name(for: entry.language)
    }
}
