import AppKit
import Foundation

/// Captures every pasteboard item with all its representations so the paste inserter
/// can put back exactly what the user had — images and file references included, not
/// just plain text.
struct PasteboardSnapshot: Sendable {
    static let defaultByteBudget = 32 * 1024 * 1024

    private let items: [[String: Data]]

    private init(items: [[String: Data]]) {
        self.items = items
    }

    var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// Lazy providers (Office, browsers) can take long to render; this keeps that wait off the main actor.
    @concurrent
    static func capture(named name: NSPasteboard.Name, byteBudget: Int = defaultByteBudget) async -> PasteboardSnapshot {
        capture(from: NSPasteboard(name: name), byteBudget: byteBudget)
    }

    nonisolated static func capture(from pasteboard: NSPasteboard, byteBudget: Int = defaultByteBudget) -> PasteboardSnapshot {
        var captured: [[String: Data]] = []
        var budget = byteBudget
        var overBudget = false
        for item in pasteboard.pasteboardItems ?? [] {
            if overBudget { break }
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                if data.count > budget {
                    overBudget = true
                    break
                }
                budget -= data.count
                representations[type.rawValue] = data
            }
            captured.append(representations)
        }
        if overBudget {
            // A skipped representation would restore a lying half-item (e.g. a file
            // reference without its data); keep only the plain text instead.
            let string = pasteboard.string(forType: .string)
            captured = string.map { [[NSPasteboard.PasteboardType.string.rawValue: Data($0.utf8)]] } ?? []
        }
        return PasteboardSnapshot(items: captured.filter { !$0.isEmpty })
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        guard !restored.isEmpty else { return }
        pasteboard.writeObjects(restored)
    }
}
