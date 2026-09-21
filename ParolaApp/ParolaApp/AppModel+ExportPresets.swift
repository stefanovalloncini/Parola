import Foundation
import SwiftUI
import ParolaCore

/// Per-format batch options as they were stored before presets. Read once, to migrate.
private struct LegacyBatchFormatOptions: Codable {
    var writeToSourceFolder: Bool
    var includeTimestamps: Bool
}

extension AppModel {

    func loadExportPresets() {
        exportPresets = AppModel.normalizedExportPresets(
            readJSON([ExportPreset].self, forKey: "exportPresets") ?? ExportPreset.builtIns
        )
    }

    func saveExportPresets() {
        writeJSON(exportPresets, forKey: "exportPresets")
    }

    /// The one way the preset library changes: every add, rename, delete and move lands here.
    func setExportPresets(_ presets: [ExportPreset]) {
        exportPresets = AppModel.normalizedExportPresets(presets)
    }

    /// Drops duplicates, re-stamps the built-in flag and puts back any built-in that went missing.
    nonisolated static func normalizedExportPresets(_ presets: [ExportPreset]) -> [ExportPreset] {
        let builtInsByID = Dictionary(uniqueKeysWithValues: ExportPreset.builtIns.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var out: [ExportPreset] = []
        for preset in presets where !seen.contains(preset.id) {
            seen.insert(preset.id)
            var copy = preset
            copy.isBuiltIn = builtInsByID[preset.id] != nil
            let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.name = trimmed.isEmpty
                ? (builtInsByID[preset.id]?.name ?? preset.spec.format.displayName)
                : trimmed
            out.append(copy)
        }
        for builtIn in ExportPreset.builtIns where !seen.contains(builtIn.id) {
            out.append(builtIn)
        }
        return out
    }

    func exportPreset(id: UUID) -> ExportPreset? {
        exportPresets.first { $0.id == id }
    }

    @discardableResult
    func addExportPreset(name: String, spec: ExportSpec) -> ExportPreset {
        let preset = ExportPreset(name: name, spec: spec)
        setExportPresets(exportPresets + [preset])
        return preset
    }

    func renameExportPreset(id: UUID, to name: String) {
        guard let index = exportPresets.firstIndex(where: { $0.id == id }) else { return }
        var presets = exportPresets
        presets[index].name = name
        setExportPresets(presets)
    }

    func deleteExportPreset(id: UUID) {
        guard let preset = exportPreset(id: id), !preset.isBuiltIn else { return }
        setExportPresets(exportPresets.filter { $0.id != id })
        // A rule or a batch selection pointing at a deleted preset would silently export nothing.
        batchExportPresetIDs = batchExportPresetIDs.filter { $0 != id }
        for index in autoExportRules.indices {
            autoExportRules[index].presetIDs.removeAll { $0 == id }
        }
    }

    func moveExportPreset(id: UUID, by offset: Int) {
        guard let index = exportPresets.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard exportPresets.indices.contains(target) else { return }
        var presets = exportPresets
        presets.swapAt(index, target)
        setExportPresets(presets)
    }

    // MARK: - Batch selection

    var batchExportPresets: [ExportPreset] {
        batchExportPresetIDs.compactMap { id in exportPresets.first { $0.id == id } }
    }

    func toggleBatchExportPreset(_ id: UUID) {
        if batchExportPresetIDs.contains(id) {
            batchExportPresetIDs = batchExportPresetIDs.filter { $0 != id }
        } else if exportPreset(id: id) != nil {
            batchExportPresetIDs = batchExportPresetIDs + [id]
        }
    }

    func loadBatchExportSelection() {
        if let stored = readJSON([UUID].self, forKey: "batchExportPresets") {
            batchExportPresetIDs = stored
            return
        }
        let migrated = AppModel.migratedBatchSelection(
            formats: (defaults.string(forKey: "batchExportFormats") ?? "txt,srt")
                .split(separator: ",")
                .compactMap { ExportFormat(rawValue: String($0)) },
            legacyOptionsJSON: defaults.string(forKey: "batchExportFormatOptions") ?? "{}",
            fallbackWriteToSourceFolder: (defaults.object(forKey: "batchExportToSourceFolder") as? Bool) ?? true,
            fallbackIncludeTimestamps: defaults.bool(forKey: "batchExportIncludeTimestamps"),
            presets: exportPresets
        )
        setExportPresets(migrated.presets)
        batchExportPresetIDs = migrated.ids
    }

    /// Turns the pre-preset batch selection into preset ids, adding a preset where the old
    /// per-format options asked for something no built-in preset carries.
    nonisolated static func migratedBatchSelection(
        formats: [ExportFormat],
        legacyOptionsJSON: String,
        fallbackWriteToSourceFolder: Bool,
        fallbackIncludeTimestamps: Bool,
        presets: [ExportPreset]
    ) -> (presets: [ExportPreset], ids: [UUID]) {
        let legacy = (try? JSONDecoder().decode(
            [String: LegacyBatchFormatOptions].self,
            from: Data(legacyOptionsJSON.utf8)
        )) ?? [:]
        var library = presets
        var ids: [UUID] = []
        for format in formats {
            let options = legacy[format.rawValue] ?? LegacyBatchFormatOptions(
                writeToSourceFolder: fallbackWriteToSourceFolder,
                includeTimestamps: fallbackIncludeTimestamps
            )
            guard options.writeToSourceFolder, let builtIn = ExportPreset.builtIn(for: format) else { continue }
            guard options.includeTimestamps, !builtIn.spec.options.timestamps else {
                ids.append(builtIn.id)
                continue
            }
            var spec = builtIn.spec
            spec.options.timestamps = true
            let preset = ExportPreset(name: String(localized: "\(builtIn.name) with timestamps"), spec: spec)
            library.append(preset)
            ids.append(preset.id)
        }
        return (library, ids)
    }

    /// Merges bridge-supplied fields over the sheet's spec: `options` merges field by field,
    /// so `{"options":{"timestamps":true}}` keeps the rest of the spec.
    func mergedExportSpec(overriding raw: [String: AutomationValue]) throws -> ExportSpec {
        guard var merged = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(exportSheetSpec)) as? [String: Any] else {
            throw AutomationError.invalidArgs(field: "spec", reason: "could not encode the current export spec")
        }
        for (key, value) in raw {
            if key == "options", case .object(let fields) = value {
                var options = merged["options"] as? [String: Any] ?? [:]
                for (field, fieldValue) in fields { options[field] = fieldValue.jsonObject }
                merged["options"] = options
            } else {
                merged[key] = value.jsonObject
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(ExportSpec.self, from: data) else {
            throw AutomationError.invalidArgs(field: "spec", reason: "could not decode an ExportSpec from the given fields")
        }
        if raw["format"] != nil { return decoded.changing(format: decoded.format) }
        if raw["style"] != nil { return decoded.changing(style: decoded.style) }
        return decoded
    }
}
