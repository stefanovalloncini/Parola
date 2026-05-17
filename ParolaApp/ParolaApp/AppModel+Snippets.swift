import Foundation
import AppKit
import ParolaCore

extension AppModel {

    static let snippetsDefaultsKey = "snippets"

    func loadSnippets() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.snippetsDefaultsKey),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        snippets = decoded
    }

    func saveSnippets() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: AppModel.snippetsDefaultsKey)
        }
    }

    func makeSnippetExpander() -> SnippetExpander {
        SnippetExpander(
            snippets: snippets,
            clipboard: NSPasteboardClipboardReader()
        )
    }
}

struct NSPasteboardClipboardReader: ClipboardReader {
    func currentText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
