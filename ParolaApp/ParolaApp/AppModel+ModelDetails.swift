import AppKit
import Foundation
import ParolaCore

extension AppModel {

    /// One pasteboard block about the selected model, shared by Help ▸ Copy Model Details and the bridge.
    func modelDetailsText() -> String {
        let id = selectedModel
        guard let variant = ModelCatalog.variant(id: id) else {
            return [
                String(localized: "Model: \(id)"),
                String(localized: "This build's catalog has no entry for it."),
            ].joined(separator: "\n")
        }
        let info = availableModels.first { $0.name == id }
        let isInstalled = info?.isInstalled ?? false
        var lines = [
            String(localized: "Model: \(variant.displayName)"),
            String(localized: "Identifier: \(variant.id)"),
            String(localized: "Engine: \(variant.engineID.displayName)"),
            String(localized: "Source: \(AppModel.modelSourceLabel(variant.downloadSource))"),
            isInstalled ? String(localized: "Installed: yes") : String(localized: "Installed: no"),
        ]
        if isInstalled, let path = info?.installedURL?.path {
            lines.append(String(localized: "Path: \(path)"))
        }
        if isInstalled {
            if let measured = modelSizes[id] {
                lines.append(String(localized: "Size: \(AppFormat.byteSize(measured))"))
            } else if variant.sizeBytes > 0 {
                lines.append(String(localized: "Size: about \(AppFormat.byteSize(variant.sizeBytes))"))
            }
        }
        lines.append(String(localized: "Languages: \(AppModel.modelLanguageSummary(for: id))"))
        return lines.joined(separator: "\n")
    }

    /// The repo and folder the catalog pins this entry to — the closest it has to a version.
    nonisolated static func modelSourceLabel(_ source: ModelDownloadSource) -> String {
        source.subpath.isEmpty
            ? source.huggingFaceRepo
            : "\(source.huggingFaceRepo)/\(source.subpath)"
    }

    nonisolated static func modelLanguageSummary(for id: String) -> String {
        let supported = ModelCatalog.staticCapabilities(forID: id)?.supportedLanguages ?? .all
        switch supported {
        case .all:
            return String(localized: "every language the engine knows")
        case .only(let codes):
            if supported.isEnglishOnly { return String(localized: "English only") }
            return String(localized: "\(codes.count) languages")
        }
    }

    /// Help ▸ Copy Model Details, and the bridge command of the same name.
    func copyModelDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelDetailsText(), forType: .string)
    }
}
