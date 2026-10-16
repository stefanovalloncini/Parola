import Foundation
import SwiftUI
import ParolaCore

/// What still writes a preset, so deleting it can say what stops.
struct ExportPresetUse: Equatable {
    let ruleCount: Int
    let inBatch: Bool

    var isUsed: Bool { ruleCount > 0 || inBatch }

    var deleteMessage: String {
        let batch = ruleCount > 0 ? String(localized: "Batch runs use it too.") : String(localized: "Batch runs use it.")
        let parts = [
            ruleCount > 0 ? String(localized: "\(ruleCount) auto-export rules use it.") : nil,
            inBatch ? batch : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
    }
}

/// Per-format batch options as they were stored before presets. Read once, to migrate.
private struct LegacyBatchFormatOptions: Codable {
    var writeToSourceFolder: Bool
    var includeTimestamps: Bool
}

extension AppModel {

    func loadExportPresets() {
        setExportPresets(readJSON([ExportPreset].self, forKey: "exportPresets") ?? ExportPreset.builtIns)
    }

    func saveExportPresets() {
        writeJSON(exportPresets, forKey: "exportPresets")
    }

    /// The one way the preset library changes: every add, rename, delete and move lands here.
    func setExportPresets(_ presets: [ExportPreset]) {
        exportPresets = AppModel.normalizedExportPresets(presets, referencedIDs: referencedExportPresetIDs)
    }

    /// Ids a rule or the batch selection still points at, so normalization can put those presets back.
    private var referencedExportPresetIDs: [UUID] {
        batchExportPresetIDs + autoExportRules.flatMap(\.presetIDs)
    }

    /// Drops duplicates, re-stamps the built-in flag, puts back any built-in that went missing and
    /// materializes the format preset behind an id a saved rule or batch selection still names.
    nonisolated static func normalizedExportPresets(
        _ presets: [ExportPreset],
        referencedIDs: [UUID] = []
    ) -> [ExportPreset] {
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
            seen.insert(builtIn.id)
            out.append(builtIn)
        }
        for id in referencedIDs where !seen.contains(id) {
            guard let preset = ExportPreset.formatPreset(id: id) else { continue }
            seen.insert(id)
            out.append(preset)
        }
        return out
    }

    func exportPreset(id: UUID) -> ExportPreset? {
        exportPresets.first { $0.id == id }
    }

    /// `excluding` is the preset being renamed, so it doesn't clash with its own name.
    func exportPresetNameProblem(_ name: String, excluding id: UUID? = nil) -> ExportPresetNameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let taken = exportPresets.contains { $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return taken ? .duplicate : nil
    }

    @discardableResult
    func addExportPreset(name: String, spec: ExportSpec) -> ExportPreset {
        let preset = ExportPreset(name: name, spec: spec)
        setExportPresets(exportPresets + [preset])
        return preset
    }

    func renameExportPreset(id: UUID, to name: String) {
        guard exportPresetNameProblem(name, excluding: id) != .duplicate else { return }
        guard let index = exportPresets.firstIndex(where: { $0.id == id }) else { return }
        var presets = exportPresets
        presets[index].name = name
        setExportPresets(presets)
    }

    /// A name for the Save as Preset alert that no preset has yet, so Save starts enabled.
    func defaultExportPresetName() -> String {
        let base = String(localized: "My preset")
        var name = base
        var number = 2
        while exportPresetNameProblem(name) != nil {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    func exportPresetUse(id: UUID) -> ExportPresetUse {
        ExportPresetUse(
            ruleCount: autoExportRules.count { $0.presetIDs.contains(id) },
            inBatch: batchExportPresetIDs.contains(id)
        )
    }

    func deleteExportPreset(id: UUID) {
        guard let preset = exportPreset(id: id), !preset.isBuiltIn else { return }
        // Prune first: normalization puts a format preset straight back while a rule still names it.
        batchExportPresetIDs = batchExportPresetIDs.filter { $0 != id }
        // One assignment: the property's didSet writes the whole array on every element write.
        var rules = autoExportRules
        for index in rules.indices where rules[index].presetIDs.contains(id) {
            rules[index].presetIDs.removeAll { $0 == id }
        }
        if rules != autoExportRules { autoExportRules = rules }
        watchedFoldersIfWatching?.removeExportPreset(id)
        setExportPresets(exportPresets.filter { $0.id != id })
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
        setBatchExportPreset(id, selected: !batchExportPresetIDs.contains(id))
    }

    /// The one way the batch selection changes: a preset the library does not hold cannot be selected.
    func setBatchExportPreset(_ id: UUID, selected: Bool) {
        guard selected else {
            batchExportPresetIDs = batchExportPresetIDs.filter { $0 != id }
            return
        }
        guard exportPreset(id: id) != nil, !batchExportPresetIDs.contains(id) else { return }
        batchExportPresetIDs = batchExportPresetIDs + [id]
    }

    func loadBatchExportSelection() {
        if let stored = readJSON([UUID].self, forKey: "batchExportPresets") {
            batchExportPresetIDs = stored
        } else {
            let migrated = AppModel.migratedBatchSelection(
                formats: (defaults.string(forKey: "batchExportFormats") ?? "txt,srt")
                    .split(separator: ",")
                    .compactMap { ExportFormat(rawValue: String($0)) },
                legacyOptionsJSON: defaults.string(forKey: "batchExportFormatOptions") ?? "{}",
                fallbackWriteToSourceFolder: (defaults.object(forKey: "batchExportToSourceFolder") as? Bool) ?? true,
                fallbackIncludeTimestamps: defaults.bool(forKey: "batchExportIncludeTimestamps"),
                presets: exportPresets
            )
            batchExportPresetIDs = migrated.ids
            exportPresets = migrated.presets
        }
        // The selection is known only now, so re-normalize: a format preset a migrated id names appears here.
        setExportPresets(exportPresets)
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
            guard options.writeToSourceFolder else { continue }
            let builtIn = ExportPreset.formatPreset(for: format)
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
        if raw["style"] != nil { return decoded.changing(style: decoded.style) }
        // Always mask: setExportSpec re-masks whatever it is handed, and the two commands must not
        // read the same JSON differently.
        return decoded.changing(format: decoded.format)
    }
}

enum ExportPresetNameProblem: Equatable {
    case empty
    case duplicate
}
