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

    static func isMachineName(_ title: String) -> Bool {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = base.lastIndex(of: "."), dot != base.startIndex,
           base.distance(from: base.index(after: dot), to: base.endIndex) <= 5 {
            base = String(base[..<dot])
        }
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let pattern = "^(parola-[a-z]+-)?\(uuid)$"
        return base.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
