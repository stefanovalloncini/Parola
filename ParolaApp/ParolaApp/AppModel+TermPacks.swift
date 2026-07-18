import Foundation
import AppKit
import UniformTypeIdentifiers
import ParolaCore

extension AppModel {

    func presentTermPackImporter() {
        Task { [weak self] in
            guard let self else { return }
            let urls = await self.filePicker.chooseInputFiles(
                allowedTypes: [.json],
                allowsMultiple: false,
                message: "Pick a Parola term pack (.json)."
            )
            guard let url = urls.first else { return }
            await self.importTermPack(from: url)
        }
    }

    func importTermPack(from url: URL) async {
        do {
            let pack = try await Self.offMainIO {
                let data = try Data(contentsOf: url)
                return try TermPackIO.decode(data)
            }
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
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.filePicker.chooseSaveDestination(
                suggestedName: "parola-terms.json",
                allowedTypes: [.json]
            ) else { return }
            do {
                let locale = Locale.current.language.languageCode?.identifier ?? "en"
                let pack = TermPackIO.pack(
                    from: self.findReplaceRules.filter { !$0.find.isEmpty },
                    name: "Parola Terms (\(locale))",
                    locale: locale
                )
                let data = try TermPackIO.encode(pack)
                try data.write(to: url, options: .atomic)
            } catch {
                self.phase = .failed(message: "Couldn't export term pack: \(error.localizedDescription)")
            }
        }
    }
}
