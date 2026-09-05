import Foundation
import Testing
@testable import Parola

@Suite("Speaker palette contrast")
struct SpeakerPaletteTests {

    private static let minimum = 4.5

    private static func pair(_ color: ThemeColor) -> (light: RGBA, dark: RGBA)? {
        guard case .dynamic(let light, let dark) = color else { return nil }
        return (light, dark)
    }

    @Test("every tint has a separate light and dark variant")
    func variantsDiffer() throws {
        for tint in DS.speakerTints {
            let variants = try #require(Self.pair(tint))
            #expect(variants.light != variants.dark)
        }
    }

    @Test("every tint clears AA on the segment-card fill in both schemes")
    func clearsAAOnCardFill() throws {
        let fill = try #require(Self.pair(ThemePalette.sharedNeutrals.surfaceElevated))
        for tint in DS.speakerTints {
            let variants = try #require(Self.pair(tint))
            #expect(
                variants.light.contrast(against: fill.light) >= Self.minimum,
                "\(variants.light.hex) on \(fill.light.hex)"
            )
            #expect(
                variants.dark.contrast(against: fill.dark) >= Self.minimum,
                "\(variants.dark.hex) on \(fill.dark.hex)"
            )
        }
    }

    @Test("every tint clears AA on the plain surface too")
    func clearsAAOnSurface() throws {
        let surface = try #require(Self.pair(ThemePalette.sharedNeutrals.surface))
        for tint in DS.speakerTints {
            let variants = try #require(Self.pair(tint))
            #expect(variants.light.contrast(against: surface.light) >= Self.minimum)
            #expect(variants.dark.contrast(against: surface.dark) >= Self.minimum)
        }
    }

    @Test("the palette exposes one color per tint")
    func paletteMatchesTints() {
        #expect(DS.speakerPalette.count == DS.speakerTints.count)
    }

    @Test("speakerColor is stable for the same label")
    func stableHashing() {
        #expect(DS.speakerColor(for: "Marta") == DS.speakerColor(for: " Marta "))
        #expect(DS.speakerPalette.contains(DS.speakerColor(for: "Giulio")))
    }
}
