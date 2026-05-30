import Foundation
import SwiftUI
import Testing
@testable import Parola

@Suite("Theme color model")
struct ThemeTests {

    @Test("parses #RRGGBB into normalized components", arguments: [
        ("#000000", RGBA(0, 0, 0, 1)),
        ("#FFFFFF", RGBA(1, 1, 1, 1)),
        ("#FF0000", RGBA(1, 0, 0, 1)),
        ("#00FF00", RGBA(0, 1, 0, 1)),
        ("#0000FF", RGBA(0, 0, 1, 1)),
    ])
    func parsesSixDigitHex(input: String, expected: RGBA) throws {
        let parsed = try #require(RGBA(hex: input))
        #expect(parsed == expected)
    }

    @Test("parses #RRGGBBAA including the alpha channel")
    func parsesEightDigitHex() throws {
        let opaque = try #require(RGBA(hex: "#112233FF"))
        #expect(opaque.a == 1)
        #expect(opaque.r == Double(0x11) / 255)
        #expect(opaque.g == Double(0x22) / 255)
        #expect(opaque.b == Double(0x33) / 255)

        let half = try #require(RGBA(hex: "#11223380"))
        #expect(half.a == Double(0x80) / 255)
    }

    @Test("accepts hex with no leading hash")
    func parsesWithoutHash() throws {
        let withHash = try #require(RGBA(hex: "#3366CC"))
        let without = try #require(RGBA(hex: "3366CC"))
        #expect(withHash == without)
    }

    @Test("is case-insensitive")
    func parsesLowercase() throws {
        let upper = try #require(RGBA(hex: "#AABBCC"))
        let lower = try #require(RGBA(hex: "#aabbcc"))
        #expect(upper == lower)
    }

    @Test("trims surrounding whitespace before parsing")
    func parsesWithWhitespace() throws {
        let trimmed = try #require(RGBA(hex: "  #ABCDEF  "))
        let direct = try #require(RGBA(hex: "#ABCDEF"))
        #expect(trimmed == direct)
    }

    @Test("rejects malformed input", arguments: [
        "",
        "#",
        "#FFF",
        "#FFFFF",
        "#FFFFFFF",
        "#GGGGGG",
        "#12345G",
        "not a color",
        "#FFFFFFFFF",
    ])
    func rejectsBadHex(input: String) {
        #expect(RGBA(hex: input) == nil)
    }

    @Test("hex emits an uppercase six-digit string and drops alpha")
    func hexString() {
        #expect(RGBA(0, 0, 0).hex == "#000000")
        #expect(RGBA(1, 1, 1).hex == "#FFFFFF")
        #expect(RGBA(1, 0, 0).hex == "#FF0000")
        #expect(RGBA(0.2, 0.4, 0.6, 0.5).hex == "#336699")
    }

    @Test("hex rounds component values to the nearest byte")
    func hexRounds() {
        let nearlyOne = RGBA(254.6 / 255, 0, 0)
        #expect(nearlyOne.hex == "#FF0000")
    }

    @Test("six-digit hex survives a parse then re-encode round-trip", arguments: [
        "#000000", "#FFFFFF", "#123456", "#ABCDEF", "#778899",
    ])
    func hexRoundTrip(input: String) throws {
        let parsed = try #require(RGBA(hex: input))
        #expect(parsed.hex == input)
    }
}

@Suite("Theme palette and presets")
struct ThemePaletteTests {

    @Test("every preset carries a non-empty label and a stable id")
    func presetLabelsAndIds() {
        for preset in ThemePreset.allCases {
            #expect(preset.label.isEmpty == false)
            #expect(preset.id == preset.rawValue)
        }
    }

    @Test("preset labels map to the marketing names")
    func presetLabelMapping() {
        #expect(ThemePreset.terracotta.label == "Terracotta")
        #expect(ThemePreset.blue.label == "Ocean")
        #expect(ThemePreset.mint.label == "Forest")
        #expect(ThemePreset.graphite.label == "Mono")
    }

    @Test("a preset palette uses system text colors and the shared neutrals")
    func presetPaletteShape() {
        let palette = ThemePreset.blue.palette
        #expect(palette.textPrimary == .system(.primary))
        #expect(palette.textSecondary == .system(.secondary))
        #expect(palette.danger == .system(.red))
        #expect(palette.canvas == ThemePalette.sharedNeutrals.canvas)
        #expect(palette.surface == ThemePalette.sharedNeutrals.surface)
        #expect(palette.accent == ThemePreset.blue.accent)
    }

    @Test("uniform builds a dynamic color with matching light and dark values")
    func uniformColor() {
        let rgba = RGBA(0.1, 0.2, 0.3)
        #expect(ThemeColor.uniform(rgba) == .dynamic(light: rgba, dark: rgba))
    }

    @Test("custom palette wraps every editable color as a uniform token")
    func customPalette() {
        let palette = ThemePalette.custom(
            accent: .red, canvas: .white, surface: .white, surfaceElevated: .gray,
            divider: .black, textPrimary: .black, textSecondary: .gray
        )
        #expect(palette.accent.isUniform)
        #expect(palette.canvas.isUniform)
        #expect(palette.textPrimary.isUniform)
        #expect(palette.success == ThemePalette.sharedNeutrals.success)
        #expect(palette.warning == ThemePalette.sharedNeutrals.warning)
        #expect(palette.danger == .system(.red))
    }

    @Test("selection resolves a preset case to that preset's palette")
    func selectionPreset() {
        let selection = ThemeSelection.preset(.mint)
        #expect(selection.palette == ThemePreset.mint.palette)
        #expect(selection.isCustom == false)
    }

    @Test("selection passes a custom palette through untouched")
    func selectionCustom() {
        let palette = ThemePreset.purple.palette
        let selection = ThemeSelection.custom(palette)
        #expect(selection.palette == palette)
        #expect(selection.isCustom)
    }

    @Test("a palette round-trips through Codable")
    func paletteCodableRoundTrip() throws {
        let palette = ThemePreset.terracotta.palette
        let data = try JSONEncoder().encode(palette)
        let decoded = try JSONDecoder().decode(ThemePalette.self, from: data)
        #expect(decoded == palette)
    }

    @Test("a custom palette round-trips through Codable")
    func customPaletteCodableRoundTrip() throws {
        let palette = ThemePalette.custom(
            accent: .red, canvas: .white, surface: .white, surfaceElevated: .gray,
            divider: .black, textPrimary: .black, textSecondary: .gray
        )
        let data = try JSONEncoder().encode(palette)
        let decoded = try JSONDecoder().decode(ThemePalette.self, from: data)
        #expect(decoded == palette)
    }

    @Test("ThemeColor round-trips both dynamic and system cases through Codable")
    func themeColorCodableRoundTrip() throws {
        let dynamic = ThemeColor.dynamic(light: RGBA(0.1, 0.2, 0.3), dark: RGBA(0.4, 0.5, 0.6, 0.7))
        let system = ThemeColor.system(.secondary)
        for color in [dynamic, system] {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(ThemeColor.self, from: data)
            #expect(decoded == color)
        }
    }
}

private extension ThemeColor {
    var isUniform: Bool {
        if case .dynamic(let light, let dark) = self { return light == dark }
        return false
    }
}
