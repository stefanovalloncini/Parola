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
        Task { [weak self] in
            do {
                try await AppModel.offMainIO {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(items).write(to: url, options: .atomic)
                }
            } catch {
                ParolaLog.error(.export, "snippets export failed", [.error: .error(error)])
                self?.exportNotice = .failed(error)
            }
        }
    }

    func importSnippetsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            do {
                let imported = try await AppModel.offMainIO {
                    try JSONDecoder().decode([Snippet].self, from: Data(contentsOf: url))
                }
                guard let self else { return }
                let existing = Set(self.snippets.map { $0.trigger.lowercased() })
                self.snippets += imported.filter { !existing.contains($0.trigger.lowercased()) }
            } catch {
                self?.phase = .failed(message: "Import failed: \(error.localizedDescription)")
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
