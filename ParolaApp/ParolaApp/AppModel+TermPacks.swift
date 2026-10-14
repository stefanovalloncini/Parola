import Foundation
import AppKit
import UniformTypeIdentifiers
import ParolaCore

extension AppModel {

    func presentTermPackImporter() {
        Task { [weak self] in
            guard let self else { return }
            let urls = await self.filePicker.chooseInputFiles(
                allowedTypes: [.json, .commaSeparatedText, .tabSeparatedText, .plainText],
                allowsMultiple: false,
                message: String(localized: "Pick a term pack (.json) or a list of replacements (.csv, .tsv, .txt).")
            )
            guard let url = urls.first else { return }
            await self.importRulesFile(from: url)
        }
    }

    func importRulesFile(from url: URL) async {
        guard url.pathExtension.lowercased() != "json" else {
            await importTermPack(from: url)
            return
        }
        do {
            let list = try await Self.offMainIO {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                return ReplacementList.parse(text, fileExtension: url.pathExtension)
            }
            let pack = TermPack(name: url.lastPathComponent, locale: "", rules: list.rules)
            let added = TermPackIO.merge(pack: pack, into: findReplaceRules).count - findReplaceRules.count
            pendingRuleImport = PendingRuleImport(fileName: url.lastPathComponent, pack: pack, newRuleCount: added, skippedLines: list.skippedLines)
        } catch {
            phase = .failed(message: String(localized: "Couldn't import term pack: \(FailureText.message(for: error))"))
        }
    }

    func confirmRuleImport() {
        guard let pending = pendingRuleImport else { return }
        pendingRuleImport = nil
        findReplaceRules = TermPackIO.merge(pack: pending.pack, into: findReplaceRules)
    }

    func cancelRuleImport() {
        pendingRuleImport = nil
    }

    func importTermPack(from url: URL) async {
        do {
            let pack = try await Self.offMainIO {
                let data = try Data(contentsOf: url)
                return try TermPackIO.decode(data)
            }
            findReplaceRules = TermPackIO.merge(pack: pack, into: findReplaceRules)
        } catch {
            phase = .failed(message: String(localized: "Couldn't import term pack: \(FailureText.message(for: error))"))
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
                OutputMarker.mark(url)
            } catch {
                ParolaLog.error(.export, "term pack export failed", [.error: .error(error)])
                self.exportNotice = .failed(error)
            }
        }
    }
}

struct PendingRuleImport: Equatable {
    let fileName: String
    let pack: TermPack
    let newRuleCount: Int
    let skippedLines: Int

    var title: String {
        newRuleCount == 0
            ? String(localized: "Nothing to import")
            : String(localized: "Import \(newRuleCount) rules from “\(fileName)”?")
    }

    var message: String {
        let skipped = skippedLines > 0 ? String(localized: "\(skippedLines) lines skipped.") : nil
        guard newRuleCount > 0 else {
            let none = String(localized: "No new find → replace lines in “\(fileName)”.")
            return skipped.map { none + " " + $0 } ?? none
        }
        let base = String(localized: "Imported rules match whole words.")
        return skipped.map { base + " " + $0 } ?? base
    }
}
