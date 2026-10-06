import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export options placement", .serialized)
struct ExportOptionsPlacementTests {
    private static let optionLeaves = ["Picker.SubtitleLength", "Toggle.MarkdownTimestamps", "Toggle.TxtTimestamps", "Picker.HtmlTheme"]
    private static let optionKeys = ["subtitleCaptionLength", "markdownTimestamps", "txtExportTimestamps", "htmlExportTheme"]

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("export-options"))
    }

    private func elements(of view: some View, model: AppModel) -> [HostedAccessibility.Element] {
        let hosted = HostedWindow(ScrollView { view.padding() }.environment(model), width: 900, height: 2000)
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
    }

    @Test("the export options sit on Export Presets, not Auto-Export")
    func optionsLiveWithThePresets() {
        let model = makeModel()
        let presetIDs = elements(of: ExportFormatsPane(), model: model).compactMap(\.identifier)
        let autoIDs = elements(of: AutoExportPane(), model: model).compactMap(\.identifier)
        for leaf in Self.optionLeaves {
            #expect(presetIDs.contains { $0.hasSuffix("ExportFormats.\(leaf)") }, "Export Presets lacks \(leaf)")
            #expect(!autoIDs.contains { $0.hasSuffix(leaf) }, "Auto-Export still holds \(leaf)")
        }
    }

    @Test("Export Presets' reset and search cover the export options")
    func scopeFollowsTheOptions() {
        for key in Self.optionKeys {
            #expect(SettingsPaneScope.exportFormats.resetKeys(features: .all).contains(key), "\(key)")
            #expect(!SettingsPaneScope.autoExport.defaultsKeys.contains(key), "\(key)")
        }
        #expect(SettingsSidebarCatalog.matches(route: .exportFormats, query: "html theme"))
        #expect(SettingsSidebarCatalog.matches(route: .exportFormats, query: "line length"))
        #expect(!SettingsSidebarCatalog.matches(route: .autoExport, query: "html theme"))
    }

    @Test("Auto-Export explains itself in one sentence, and an empty extension field says it matches any file")
    func autoExportCopy() throws {
        let model = makeModel()
        model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [])]
        let found = elements(of: AutoExportPane(), model: model)
        let words = found.flatMap(\.words)
        #expect(!words.contains { $0.contains("Leave a rule's extension field empty") })
        let field = try #require(found.first { $0.identifier?.hasSuffix("AutoExport.TextField.Extensions") == true })
        #expect(field.placeholder == String(localized: "Any file"))
    }
}
