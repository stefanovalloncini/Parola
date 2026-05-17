import Foundation
import AppKit
import ParolaCore

extension AppModel {

    static let snippetsDefaultsKey = "snippets"

    func loadSnippets() {
        if let decoded = AppModel.readJSON([Snippet].self, forKey: AppModel.snippetsDefaultsKey) {
            snippets = decoded
        }
    }

    func saveSnippets() {
        AppModel.writeJSON(snippets, forKey: AppModel.snippetsDefaultsKey)
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
