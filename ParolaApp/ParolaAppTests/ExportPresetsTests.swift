import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export presets")
struct ExportPresetsTests {

    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: defaults ?? temporaryDefaults(),
            libraryURL: makeTempLibraryURL("export-presets")
        )
    }

    private var txtPreset: ExportPreset { ExportPreset.builtIn(for: .txt)! }
    private var srtPreset: ExportPreset { ExportPreset.builtIn(for: .srt)! }

    @Test("a fresh model starts with the built-in presets")
    func startsWithBuiltIns() {
        let model = makeModel()
        #expect(model.exportPresets.map(\.id) == ExportPreset.builtIns.map(\.id))
    }

    @Test("adding a preset appends it and persists the library")
    func addPersists() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults: defaults)

        let added = model.addExportPreset(name: "Reels", spec: .standard(for: .srt))

        #expect(model.exportPresets.last?.id == added.id)
        #expect(model.exportPresets.last?.isBuiltIn == false)

        let reloaded = makeModel(defaults: defaults)
        #expect(reloaded.exportPresets.last?.name == "Reels")
    }

    @Test("renaming trims the name and leaves a blank one on the old name")
    func renameTrims() {
        let model = makeModel()
        let added = model.addExportPreset(name: "Reels", spec: .standard(for: .srt))

        model.renameExportPreset(id: added.id, to: "  Shorts  ")
        #expect(model.exportPreset(id: added.id)?.name == "Shorts")

        model.renameExportPreset(id: added.id, to: "   ")
        #expect(model.exportPreset(id: added.id)?.name == ExportFormat.srt.displayName)
    }

    @Test("a built-in preset cannot be deleted")
    func builtInsSurviveDelete() {
        let model = makeModel()
        model.deleteExportPreset(id: txtPreset.id)
        #expect(model.exportPreset(id: txtPreset.id) != nil)
    }

    @Test("deleting a preset also drops it from the batch selection and the rules")
    func deletePrunesReferences() {
        let model = makeModel()
        let added = model.addExportPreset(name: "Reels", spec: .standard(for: .srt))
        model.toggleBatchExportPreset(added.id)
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [added.id, txtPreset.id])]

        model.deleteExportPreset(id: added.id)

        #expect(model.exportPreset(id: added.id) == nil)
        #expect(!model.batchExportPresetIDs.contains(added.id))
        #expect(model.autoExportRules.first?.presetIDs == [txtPreset.id])
    }

    @Test("moving a preset swaps it with its neighbour and stops at the ends")
    func moveWithinBounds() {
        let model = makeModel()
        let first = model.exportPresets[0].id
        let second = model.exportPresets[1].id

        model.moveExportPreset(id: second, by: -1)
        #expect(model.exportPresets.map(\.id).prefix(2) == [second, first])

        model.moveExportPreset(id: second, by: -1)
        #expect(model.exportPresets.map(\.id).prefix(2) == [second, first])
    }

    @Test("setExportPresets drops duplicates and puts back a missing built-in")
    func normalizationRepairsTheLibrary() {
        let model = makeModel()
        let stray = ExportPreset(id: txtPreset.id, name: "Renamed text", spec: .standard(for: .txt))

        model.setExportPresets([stray, stray])

        #expect(model.exportPresets.filter { $0.id == txtPreset.id }.count == 1)
        #expect(model.exportPreset(id: txtPreset.id)?.isBuiltIn == true)
        #expect(model.exportPreset(id: txtPreset.id)?.name == "Renamed text")
        #expect(model.exportPresets.count == ExportPreset.builtIns.count)
    }

    @Test("toggling a batch preset adds it once and removes it again")
    func toggleBatchSelection() {
        let model = makeModel()
        model.batchExportPresetIDs = []

        model.toggleBatchExportPreset(srtPreset.id)
        model.toggleBatchExportPreset(srtPreset.id)
        #expect(model.batchExportPresetIDs.isEmpty)

        model.toggleBatchExportPreset(srtPreset.id)
        model.toggleBatchExportPreset(srtPreset.id)
        model.toggleBatchExportPreset(srtPreset.id)
        #expect(model.batchExportPresetIDs == [srtPreset.id])

        model.toggleBatchExportPreset(UUID())
        #expect(model.batchExportPresetIDs == [srtPreset.id])
    }

    @Test("the legacy batch formats migrate to the built-in presets once")
    func batchSelectionMigrates() {
        let defaults = temporaryDefaults()
        defaults.set("srt,txt", forKey: "batchExportFormats")

        let model = makeModel(defaults: defaults)

        #expect(model.batchExportPresetIDs == [srtPreset.id, txtPreset.id])
        #expect(model.batchExportPresets.map(\.spec.format) == [.srt, .txt])

        defaults.set("csv", forKey: "batchExportFormats")
        let reloaded = makeModel(defaults: defaults)
        #expect(reloaded.batchExportPresetIDs == [srtPreset.id, txtPreset.id])
    }

    @Test("a legacy format that was not written to the source folder migrates to nothing")
    func batchMigrationHonoursWriteToSourceFolder() {
        let defaults = temporaryDefaults()
        defaults.set("txt", forKey: "batchExportFormats")
        defaults.set(#"{"txt":{"writeToSourceFolder":false,"includeTimestamps":false}}"#, forKey: "batchExportFormatOptions")

        let model = makeModel(defaults: defaults)

        #expect(model.batchExportPresetIDs.isEmpty)
    }

    @Test("a legacy format that wanted timestamps migrates to a preset that carries them")
    func batchMigrationKeepsTimestamps() {
        let defaults = temporaryDefaults()
        defaults.set("txt", forKey: "batchExportFormats")
        defaults.set(#"{"txt":{"writeToSourceFolder":true,"includeTimestamps":true}}"#, forKey: "batchExportFormatOptions")

        let model = makeModel(defaults: defaults)

        let selected = model.batchExportPresets
        #expect(selected.count == 1)
        #expect(selected.first?.spec.format == .txt)
        #expect(selected.first?.spec.options.timestamps == true)
        #expect(selected.first?.isBuiltIn == false)
        #expect(model.exportPresets.contains { $0.id == selected.first?.id })
    }

    @Test("a legacy format without a built-in preset migrates to nothing")
    func batchMigrationSkipsFormatsWithoutAPreset() {
        let defaults = temporaryDefaults()
        defaults.set("csv,txt", forKey: "batchExportFormats")

        let model = makeModel(defaults: defaults)

        #expect(model.batchExportPresetIDs == [txtPreset.id])
    }

    @Test("a rule saved with output formats loads onto the built-in presets")
    func autoExportRuleMigrates() throws {
        let defaults = temporaryDefaults()
        let legacy = """
        [{"id":"22222222-2222-2222-2222-222222222222","sourceExtensions":["mp4"],"outputFormats":["srt"],"enabled":true}]
        """
        defaults.set(Data(legacy.utf8), forKey: "autoExportRules")

        let model = makeModel(defaults: defaults)

        #expect(model.autoExportRules.first?.presetIDs == [srtPreset.id])
    }

    @Test("auto-export plans the presets a matching rule names")
    func autoExportPlansPresets() {
        let model = makeModel()
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srtPreset.id])]

        let planned = AutoExportEngine.plannedPresets(
            rules: model.autoExportRules,
            sourceExtension: "mp4",
            presets: model.exportPresets
        )

        #expect(planned.map(\.id) == [srtPreset.id])
    }
}
