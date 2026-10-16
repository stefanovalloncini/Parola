import Foundation
import ParolaCore

struct WatchedFolderOptions: Codable, Hashable, Sendable {
    var autoTranscribes = true
    var includesSubfolders = true
    var savesToLibrary = true
    var exportPresetIDs: [UUID] = []
    var exportsToAutoExportFolder = false

    static let `default` = WatchedFolderOptions()

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoTranscribes = try container.decodeIfPresent(Bool.self, forKey: .autoTranscribes) ?? true
        includesSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includesSubfolders) ?? true
        savesToLibrary = try container.decodeIfPresent(Bool.self, forKey: .savesToLibrary) ?? true
        exportPresetIDs = try container.decodeIfPresent([UUID].self, forKey: .exportPresetIDs) ?? []
        exportsToAutoExportFolder = try container.decodeIfPresent(Bool.self, forKey: .exportsToAutoExportFolder) ?? false
    }

    var isDefault: Bool { self == .default }

    var exportsFiles: Bool { !exportPresetIDs.isEmpty }

    /// A transcript with nowhere to go but the library is saved there, whatever the switch says.
    var keepsTranscriptInLibrary: Bool { savesToLibrary || !exportsFiles }

    var libraryToggleIsEnabled: Bool { exportsFiles }

    /// Writing to the Auto-Export folder needs formats to write and a folder chosen.
    func offersAutoExportFolder(chosen: Bool) -> Bool { exportsFiles && chosen }

    /// What the options mean once they are consistent: no formats means nothing to save to the library instead of.
    var normalized: WatchedFolderOptions {
        var copy = self
        if copy.exportPresetIDs.isEmpty {
            copy.savesToLibrary = true
            copy.exportsToAutoExportFolder = false
        }
        return copy
    }

    func presets(in library: [ExportPreset]) -> [ExportPreset] {
        exportPresetIDs.compactMap { id in library.first { $0.id == id } }
    }

    /// One line under the folder's name for anything that isn't a default; nil when everything is.
    func summary(presets library: [ExportPreset], bundle: Bundle = .main) -> String? {
        var parts: [String] = []
        if !autoTranscribes { parts.append(String(localized: "Waits in Batch", bundle: bundle)) }
        if !includesSubfolders { parts.append(String(localized: "Only this folder", bundle: bundle)) }
        let formats = presets(in: library).map { $0.spec.format.fileExtension.uppercased() }
        if !formats.isEmpty {
            var seen = Set<String>()
            let list = formats.filter { seen.insert($0).inserted }.joined(separator: ", ")
            parts.append(
                exportsToAutoExportFolder
                    ? String(localized: "Exports \(list) to the Auto-Export folder", bundle: bundle)
                    : String(localized: "Exports \(list)", bundle: bundle)
            )
        }
        if !keepsTranscriptInLibrary { parts.append(String(localized: "Not saved to Library", bundle: bundle)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
