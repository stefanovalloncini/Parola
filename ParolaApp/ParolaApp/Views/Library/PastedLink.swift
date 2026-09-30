import AppKit
import Foundation

/// What ⌘V on the Library page hands the link sheet: one web address, or nothing.
enum PastedLink {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// Read straight off the pasteboard: item providers only load asynchronously, and Paste's enablement needs the answer now.
    static func url(on pasteboard: NSPasteboard) -> URL? {
        let items = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if let item = items.first, let link = url(from: item.absoluteString) { return link }
        return pasteboard.string(forType: .string).flatMap(url(from:))
    }
}
