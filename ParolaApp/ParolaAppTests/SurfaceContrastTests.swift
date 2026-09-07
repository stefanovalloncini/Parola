import AppKit
import Foundation
import Testing
@testable import Parola

@Suite("Surface elevation and text contrast")
struct SurfaceContrastTests {

    private static let minimum = 4.5

    /// What paints the main window behind every card; the app never sets it, AppKit does.
    private static let darkWindowBackdrop = RGBA(0.1176, 0.1176, 0.1176)

    private static func pair(_ color: ThemeColor) -> (light: RGBA, dark: RGBA)? {
        guard case .dynamic(let light, let dark) = color else { return nil }
        return (light, dark)
    }

    @Test("dark surfaces are lighter than the canvas and than the window backdrop")
    func darkElevationRises() throws {
        let canvas = try #require(Self.pair(ThemePalette.sharedNeutrals.canvas)).dark
        let surface = try #require(Self.pair(ThemePalette.sharedNeutrals.surface)).dark
        let elevated = try #require(Self.pair(ThemePalette.sharedNeutrals.surfaceElevated)).dark

        #expect(surface.relativeLuminance > canvas.relativeLuminance)
        #expect(elevated.relativeLuminance > surface.relativeLuminance)
        #expect(surface.relativeLuminance > Self.darkWindowBackdrop.relativeLuminance)
        #expect(elevated.relativeLuminance > Self.darkWindowBackdrop.relativeLuminance)
    }

    @Test("secondary text clears AA on every surface it lands on, in both schemes")
    func secondaryTextContrast() throws {
        let text = try #require(Self.pair(ThemePalette.sharedNeutrals.textSecondary))
        let backdrops: [(String, ThemeColor)] = [
            ("canvas", ThemePalette.sharedNeutrals.canvas),
            ("surface", ThemePalette.sharedNeutrals.surface),
            ("surfaceElevated", ThemePalette.sharedNeutrals.surfaceElevated),
        ]
        for (name, backdrop) in backdrops {
            let variants = try #require(Self.pair(backdrop))
            #expect(
                text.light.contrast(against: variants.light) >= Self.minimum,
                "light secondary on \(name)"
            )
            #expect(
                text.dark.contrast(against: variants.dark) >= Self.minimum,
                "dark secondary on \(name)"
            )
        }
        #expect(text.dark.contrast(against: Self.darkWindowBackdrop) >= Self.minimum)
    }

    @Test("the caption overlay's red stays bright whatever the app theme is",
          arguments: ThemePreset.allCases)
    func dangerOnDarkContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let overlay = try #require(Self.pair(palette.dangerOnDark))
        // The overlay's own scrim is a 60% black wash under a material; the dark canvas is the
        // lightest it can plausibly composite to.
        let scrim = try #require(Self.pair(palette.canvas)).dark
        #expect(overlay.light == overlay.dark, "the overlay ignores the scheme")
        #expect(overlay.light.contrast(against: RGBA(0, 0, 0)) >= Self.minimum)
        #expect(overlay.light.contrast(against: scrim) >= Self.minimum)
    }

    @Test("accent text clears AA on the card fill for every preset", arguments: ThemePreset.allCases)
    func accentTextContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let text = try #require(Self.pair(palette.accentText))
        let fill = try #require(Self.pair(palette.surfaceElevated))
        #expect(text.light.contrast(against: fill.light) >= Self.minimum, "\(preset.rawValue) light")
        #expect(text.dark.contrast(against: fill.dark) >= Self.minimum, "\(preset.rawValue) dark")
    }

    /// Every fill an accent-coloured label is set on. A new one belongs here, not on an eyeballed pair.
    private static func accentTextBackdrops(_ palette: ThemePalette) -> [(String, ThemeColor)] {
        [
            ("the run readout", palette.accentWash),
            ("the inspector's label chips", palette.accentWash),
        ]
    }

    @Test("accent text clears AA on every fill it is set on", arguments: ThemePreset.allCases)
    func accentPillContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let text = try #require(Self.pair(palette.accentText))
        for (site, backdrop) in Self.accentTextBackdrops(palette) {
            let fill = try #require(Self.pair(backdrop))
            #expect(
                text.light.contrast(against: fill.light) >= Self.minimum,
                "\(preset.rawValue) light, \(site)"
            )
            #expect(
                text.dark.contrast(against: fill.dark) >= Self.minimum,
                "\(preset.rawValue) dark, \(site)"
            )
        }
    }

    @Test("the readout fill still carries accent rather than collapsing into the surface",
          arguments: ThemePreset.allCases)
    func accentWashStaysTinted(preset: ThemePreset) throws {
        let palette = preset.palette
        let wash = try #require(Self.pair(palette.accentWash))
        let surface = try #require(Self.pair(palette.surface))
        #expect(wash.light != surface.light)
        #expect(wash.dark != surface.dark)
    }

    @Test("red and green as text clear AA on both surfaces, both schemes",
          arguments: ThemePreset.allCases)
    func statusTextContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let surface = try #require(Self.pair(palette.surface))
        let card = try #require(Self.pair(palette.surfaceElevated))
        for (name, token) in [("danger", palette.dangerText), ("success", palette.successText)] {
            let text = try #require(Self.pair(token))
            #expect(text.light.contrast(against: surface.light) >= Self.minimum, "\(name) light on surface")
            #expect(text.light.contrast(against: card.light) >= Self.minimum, "\(name) light on card")
            #expect(text.dark.contrast(against: surface.dark) >= Self.minimum, "\(name) dark on surface")
            #expect(text.dark.contrast(against: card.dark) >= Self.minimum, "\(name) dark on card")
        }
    }

    @Test("accent text leaves an accent that already clears AA alone")
    func accentTextKeepsLegibleAccents() {
        let dark = RGBA(0.1, 0.1, 0.1)
        #expect(dark.legible(on: RGBA(1, 1, 1)) == dark)
    }

    @Test("legible walks toward the far end of the scale")
    func legibleDirection() {
        let pale = RGBA(0.96, 0.78, 0.20)
        let onWhite = pale.legible(on: RGBA(1, 1, 1))
        #expect(onWhite.relativeLuminance < pale.relativeLuminance)
        #expect(onWhite.contrast(against: RGBA(1, 1, 1)) >= RGBA.textContrastMinimum)

        let onBlack = RGBA(0.2, 0.2, 0.25).legible(on: RGBA(0.1, 0.1, 0.1))
        #expect(onBlack.relativeLuminance > 0.2)
        #expect(onBlack.contrast(against: RGBA(0.1, 0.1, 0.1)) >= RGBA.textContrastMinimum)
    }
}
