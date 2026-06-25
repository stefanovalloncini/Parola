import Foundation
import AppKit
import ParolaCore
import ParolaDictation

extension AppModel {

    static let snippetsDefaultsKey = "snippets"
    static let correctionRulesDefaultsKey = "correctionRules"

    func loadSnippets() {
        snippets = readJSON([Snippet].self, forKey: AppModel.snippetsDefaultsKey) ?? []
    }

    func saveSnippets() {
        writeJSON(snippets, forKey: AppModel.snippetsDefaultsKey)
    }

    func exportSnippetsToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "parola-snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = snippets
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(items)
                try data.write(to: url, options: .atomic)
            } catch {
                await MainActor.run {
                    self?.phase = .failed(message: AppModel.exportFailureMessage(for: error))
                }
            }
        }
    }

    func importSnippetsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode([Snippet].self, from: data)
                await MainActor.run {
                    guard let self else { return }
                    let existing = Set(self.snippets.map { $0.trigger.lowercased() })
                    self.snippets += imported.filter { !existing.contains($0.trigger.lowercased()) }
                }
            } catch {
                await MainActor.run {
                    self?.phase = .failed(message: "Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func loadCorrectionRules() {
        correctionRules = readJSON([CorrectionRule].self, forKey: AppModel.correctionRulesDefaultsKey) ?? []
    }

    func saveCorrectionRules() {
        writeJSON(correctionRules, forKey: AppModel.correctionRulesDefaultsKey)
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
