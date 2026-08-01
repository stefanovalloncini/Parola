import Foundation
import ParolaCore

enum LibraryEntryDisplay {
    static func title(for entry: LibraryEntry) -> String {
        title(raw: entry.title, createdAt: entry.createdAt)
    }

    static func title(raw: String, createdAt: Date) -> String {
        guard isMachineName(raw) else { return raw }
        let stamp = createdAt.formatted(date: .abbreviated, time: .shortened)
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

/// Every string a library row draws, formatted once per entry snapshot instead of once per render.
struct LibraryRowDisplay: Identifiable {
    let entry: LibraryEntry
    let title: String
    let timestamp: String
    let sizeLabel: String?
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
        timestamp = entry.createdAt.formatted(Self.shortStamp)
        if let sizeBytes, sizeBytes > 0 {
            sizeLabel = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        } else {
            sizeLabel = nil
        }
        languageLabel = LanguageDisplay.name(for: entry.language)
        lastOpened = entry.lastOpenedAt?.formatted(.relative(presentation: .named))

        var parts = [title, entry.createdAt.formatted(Self.longStamp)]
        if !entry.labels.isEmpty {
            parts.append("Labels: \(entry.labels.joined(separator: ", "))")
        }
        if entry.pinned {
            parts.append("Pinned")
        }
        tooltip = parts.joined(separator: "\n")
    }

    private static let shortStamp = Date.FormatStyle(date: .abbreviated, time: .shortened)
    private static let longStamp = Date.FormatStyle(date: .long, time: .shortened)
}
