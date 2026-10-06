import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export presets pane", .serialized)
struct ExportPresetsPaneTests {
    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("preset-pane"))
        model.batchExportPresetIDs = []
        model.autoExportRules = []
        return model
    }

    private func host(_ model: AppModel) -> HostedWindow {
        HostedWindow(ScrollView { ExportFormatsPane().padding() }.environment(model), width: 900, height: 1600)
    }

    private func element(_ id: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(id) == true }
    }

    @Test("the first row can't move up and the last can't move down")
    func endsDontMove() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let first = ExportPresetChecks.slug(try #require(model.exportPresets.first))
        let last = ExportPresetChecks.slug(try #require(model.exportPresets.last))
        let middle = ExportPresetChecks.slug(model.exportPresets[1])

        #expect(try #require(element("ExportFormats.Button.MoveUp.\(first)", in: hosted)).isEnabled == false)
        #expect(try #require(element("ExportFormats.Button.MoveDown.\(first)", in: hosted)).isEnabled)
        #expect(try #require(element("ExportFormats.Button.MoveDown.\(last)", in: hosted)).isEnabled == false)
        #expect(try #require(element("ExportFormats.Button.MoveUp.\(last)", in: hosted)).isEnabled)
        #expect(try #require(element("ExportFormats.Button.MoveUp.\(middle)", in: hosted)).isEnabled)
    }

    @Test("Delete asks first when an auto-export rule writes the preset")
    func deleteAsksWhenARuleUsesIt() {
        let model = makeModel()
        let notes = model.addExportPreset(name: "Notes", spec: .standard(for: .md))
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [notes.id])]
        let hosted = host(model)
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "ExportFormats.Button.Delete.\(ExportPresetChecks.slug(notes))", in: hosted.host))
        #expect(model.exportPreset(id: notes.id) != nil)
        #expect(model.autoExportRules.first?.presetIDs == [notes.id])
    }

    @Test("Delete asks first when batch runs write the preset")
    func deleteAsksWhenBatchUsesIt() {
        let model = makeModel()
        let notes = model.addExportPreset(name: "Notes", spec: .standard(for: .md))
        model.setBatchExportPreset(notes.id, selected: true)
        let hosted = host(model)
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "ExportFormats.Button.Delete.\(ExportPresetChecks.slug(notes))", in: hosted.host))
        #expect(model.exportPreset(id: notes.id) != nil)
    }

    @Test("Delete removes a preset nothing uses straight away")
    func deleteUnusedAtOnce() {
        let model = makeModel()
        let notes = model.addExportPreset(name: "Notes", spec: .standard(for: .md))
        let hosted = host(model)
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "ExportFormats.Button.Delete.\(ExportPresetChecks.slug(notes))", in: hosted.host))
        #expect(model.exportPreset(id: notes.id) == nil)
    }

    @Test("the model counts the rules and the batch selection that write a preset")
    func use() {
        let model = makeModel()
        let notes = model.addExportPreset(name: "Notes", spec: .standard(for: .md))
        let other = model.addExportPreset(name: "Other", spec: .standard(for: .srt))
        model.autoExportRules = [
            AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [notes.id]),
            AutoExportRule(sourceExtensions: ["mov"], presetIDs: [other.id, notes.id]),
            AutoExportRule(sourceExtensions: ["wav"], presetIDs: [other.id]),
        ]
        model.setBatchExportPreset(other.id, selected: true)

        #expect(model.exportPresetUse(id: notes.id) == ExportPresetUse(ruleCount: 2, inBatch: false))
        #expect(model.exportPresetUse(id: other.id) == ExportPresetUse(ruleCount: 2, inBatch: true))
    }

    @Test("the question says how many rules lose the preset, and whether batch runs do")
    func deleteMessage() {
        #expect(ExportPresetUse(ruleCount: 2, inBatch: false).deleteMessage == "2 auto-export rules use it.")
        #expect(ExportPresetUse(ruleCount: 1, inBatch: false).deleteMessage == "1 auto-export rule uses it.")
        #expect(ExportPresetUse(ruleCount: 0, inBatch: true).deleteMessage == "Batch runs use it.")
        #expect(ExportPresetUse(ruleCount: 1, inBatch: true).deleteMessage == "1 auto-export rule uses it. Batch runs use it too.")
    }
}
