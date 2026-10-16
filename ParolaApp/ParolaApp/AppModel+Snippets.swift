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

    func exportSnippetsToFile() async {
        guard let url = await filePicker.chooseSaveDestination(suggestedName: "parola-snippets.json", allowedTypes: [.json]) else { return }
        let items = snippets
        do {
            try await AppModel.offMainIO {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(items).write(to: url, options: .atomic)
            }
        } catch {
            ParolaLog.error(.export, "snippets export failed", [.error: .error(error)])
            exportNotice = .failed(error)
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
                self?.phase = .failed(message: String(localized: "Import failed: \(FailureText.message(for: error))"))
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
        PendingPasteRestores.userText()
    }
}
