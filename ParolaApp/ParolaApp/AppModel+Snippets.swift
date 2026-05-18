import Foundation
import AppKit
import ParolaCore

extension AppModel {

    static let snippetsDefaultsKey = "snippets"
    static let correctionRulesDefaultsKey = "correctionRules"

    func loadSnippets() {
        if let decoded = AppModel.readJSON([Snippet].self, forKey: AppModel.snippetsDefaultsKey) {
            snippets = decoded
        }
    }

    func saveSnippets() {
        AppModel.writeJSON(snippets, forKey: AppModel.snippetsDefaultsKey)
    }

    func exportSnippetsToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "parola-snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            try data.write(to: url, options: .atomic)
        } catch {
            phase = .failed(message: "Export failed: \(error.localizedDescription)")
        }
    }

    func importSnippetsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode([Snippet].self, from: data)
            let existing = Set(snippets.map { $0.trigger.lowercased() })
            let merged = snippets + imported.filter { !existing.contains($0.trigger.lowercased()) }
            snippets = merged
        } catch {
            phase = .failed(message: "Import failed: \(error.localizedDescription)")
        }
    }

    func loadCorrectionRules() {
        if let decoded = AppModel.readJSON([CorrectionRule].self, forKey: AppModel.correctionRulesDefaultsKey) {
            correctionRules = decoded
        }
    }

    func saveCorrectionRules() {
        AppModel.writeJSON(correctionRules, forKey: AppModel.correctionRulesDefaultsKey)
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
