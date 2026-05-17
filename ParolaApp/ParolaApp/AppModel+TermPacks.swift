import Foundation
import AppKit
import UniformTypeIdentifiers
import ParolaCore

extension AppModel {

    func presentTermPackImporter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a Parola term pack (.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTermPack(from: url)
    }

    func importTermPack(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let pack = try TermPackIO.decode(data)
            findReplaceRules = TermPackIO.merge(pack: pack, into: findReplaceRules)
        } catch {
            phase = .failed(message: "Couldn't import term pack: \(error.localizedDescription)")
        }
    }

    func importBundledTermPack(named identifier: String) {
        guard let pack = BundledTermPacks.load(identifier) else {
            phase = .failed(message: "Bundled pack \(identifier) not found.")
            return
        }
        findReplaceRules = TermPackIO.merge(pack: pack, into: findReplaceRules)
    }

    func presentTermPackExporter() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "parola-terms.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let locale = Locale.current.language.languageCode?.identifier ?? "en"
            let pack = TermPackIO.pack(
                from: findReplaceRules.filter { !$0.find.isEmpty },
                name: "Parola Terms (\(locale))",
                locale: locale
            )
            let data = try TermPackIO.encode(pack)
            try data.write(to: url, options: .atomic)
        } catch {
            phase = .failed(message: "Couldn't export term pack: \(error.localizedDescription)")
        }
    }
}
