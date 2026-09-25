import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaTestSupport

/// Main-actor, and awaits only where DS.theme ends where it started, so another suite never sees it swapped.
@Suite("Custom palette edits")
@MainActor
struct CustomPaletteEditTests {

    private static let orange = ThemeColor.uniform(RGBA(0.82, 0.60, 0))

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("palette-edit"))
    }

    @Test("a well's edit is saved at once but repaints the app only when the edit ends")
    func editRepaintsWhenItEnds() throws {
        let previous = DS.theme
        defer { DS.theme = previous }
        let model = makeModel()
        model.applyCustomPalette(ThemePreset.slate.palette)
        let applied = DS.theme
        let revision = model.themeRevision

        var palette = model.editablePalette
        palette.accent = Self.orange
        model.previewCustomPalette(palette)

        #expect(DS.theme == applied)
        #expect(model.themeRevision == revision)
        #expect(model.editablePalette == palette)
        let saved = try JSONDecoder().decode(ThemePalette.self, from: Data(model.themeCustomPaletteJSON.utf8))
        #expect(saved == palette)

        model.commitPaletteDraft()
        #expect(DS.theme == palette)
        #expect(model.themeRevision == revision + 1)
        #expect(model.paletteDraft == nil)

        model.commitPaletteDraft()
        #expect(model.themeRevision == revision + 1)
    }

    @Test("edits to two wells land together")
    func editsAccumulate() {
        let previous = DS.theme
        defer { DS.theme = previous }
        let model = makeModel()
        model.applyCustomPalette(ThemePreset.slate.palette)

        var first = model.editablePalette
        first.accent = Self.orange
        model.previewCustomPalette(first)
        var second = model.editablePalette
        second.canvas = .uniform(RGBA(0.1, 0.1, 0.12))
        model.previewCustomPalette(second)
        model.commitPaletteDraft()

        #expect(DS.theme.accent == Self.orange)
        #expect(DS.theme.canvas == .uniform(RGBA(0.1, 0.1, 0.12)))
    }

    @Test("picking a preset mid-edit drops the draft")
    func presetDropsTheDraft() {
        let previous = DS.theme
        defer { DS.theme = previous }
        let model = makeModel()
        var palette = model.editablePalette
        palette.accent = Self.orange
        model.previewCustomPalette(palette)

        model.selectThemePreset(ThemePreset.teal.rawValue)

        #expect(model.paletteDraft == nil)
        #expect(model.editablePalette == ThemePreset.teal.palette)
        #expect(DS.theme == ThemePreset.teal.palette)
    }

    @Test("the translucent tokens' wells show their alpha and keep a picked one")
    func translucentWellsKeepAlpha() throws {
        let previous = DS.theme
        defer { DS.theme = previous }
        let model = makeModel()
        model.applyCustomPalette(ThemePreset.slate.palette)
        let divider = try #require(CustomPaletteWell.all.first { $0.keyPath == \ThemePalette.divider })
        #expect(abs(RGBA(divider.binding(model).wrappedValue).a - 0.08) < 0.001)

        let picked = Color(nsColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.3))
        for well in CustomPaletteWell.all where well.supportsOpacity {
            well.binding(model).wrappedValue = picked
            let stored = model.editablePalette[keyPath: well.keyPath].appearanceVariants
            #expect(abs(stored.light.a - 0.3) < 0.001, "\(well.label)")
            #expect(abs(stored.dark.a - 0.3) < 0.001, "\(well.label)")
        }
        model.commitPaletteDraft()

        #expect(abs(DS.theme.divider.appearanceVariants.dark.a - 0.3) < 0.001)
        #expect(abs(DS.theme.textPrimary.appearanceVariants.dark.a - 0.3) < 0.001)
    }

    @Test("an edit made with no colour panel open lands on its own")
    func editWithoutPanelLands() async {
        let model = makeModel()
        let revision = model.themeRevision

        model.previewCustomPalette(DS.theme)
        await model.awaitPaletteDraft()

        #expect(model.paletteDraft == nil)
        #expect(model.themeRevision == revision + 1)
    }
}
