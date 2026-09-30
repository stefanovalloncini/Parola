import AppKit
import Foundation
import ParolaCore

/// What ⌘V in the main window hands the link sheet: one address Parola can fetch, or nothing.
enum PastedLink {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil, url.isYtDlpSupported else { return nil }
        return url
    }

    /// The first URL item, else the text, the way a paste takes them.
    static func url(on pasteboard: NSPasteboard) -> URL? {
        let items = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if let item = items.first, let link = url(from: item.absoluteString) { return link }
        return pasteboard.string(forType: .string).flatMap(url(from:))
    }

    /// Looks at the kinds of data on offer, never the data: reading the contents outside a paste can make macOS ask.
    static func mayHoldLink(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.URL, .string]) != nil
    }
}
