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

    /// Steel blue (hue #3, replacing a plum too close to mauve) against every other hue and against
    /// Sage, in both appearances. Not a full 21-pair mesh: two pre-existing pairs (warm tan/ochre,
    /// dusty blue/slate-dark) already sit under 10 ΔE and are outside this fix's named scope.
    @Test("the new speaker hue clears CIEDE2000 10 from every other hue, 20 from the default accent")
    func steelBlueClearsMinimumDistances() throws {
        let steelBlue = try #require(Self.pair(DS.speakerTints[2]))
        let others = DS.speakerTints.indices.filter { $0 != 2 }.compactMap { Self.pair(DS.speakerTints[$0]) }
        #expect(others.count == DS.speakerTints.count - 1)

        for other in others {
            #expect(Self.ciede2000(steelBlue.light, other.light) >= 10)
            #expect(Self.ciede2000(steelBlue.dark, other.dark) >= 10)
        }

        let sage = try #require(Self.pair(ThemePreset.sage.accent))
        #expect(Self.ciede2000(steelBlue.light, sage.light) >= 20)
        #expect(Self.ciede2000(steelBlue.dark, sage.dark) >= 20)
    }

    // MARK: - CIEDE2000 (test-only colour-science helper; nothing in the app needs it at runtime)

    private static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func lab(_ rgba: RGBA) -> (L: Double, a: Double, b: Double) {
        let r = linear(rgba.r), g = linear(rgba.g), b = linear(rgba.b)
        let x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
        let y = (r * 0.2126729 + g * 0.7151522 + b * 0.0721750) / 1.0
        let z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The CIE ΔE2000 colour difference between two sRGB values — the perceptual metric the speaker
    /// palette's minimum-distance rule is judged by, not a flat Euclidean RGB or Lab distance.
    private static func ciede2000(_ rgba1: RGBA, _ rgba2: RGBA) -> Double {
        let (l1, a1, b1) = lab(rgba1)
        let (l2, a2, b2) = lab(rgba2)
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))).squareRoot())
        let a1p = a1 * (1 + g), a2p = a2 * (1 + g)
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()

        func hueDegrees(_ ap: Double, _ b: Double) -> Double {
            guard ap != 0 || b != 0 else { return 0 }
            let h = atan2(b, ap) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1p = hueDegrees(a1p, b1), h2p = hueDegrees(a2p, b2)

        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            let dh = h2p - h1p
            dhp = dh > 180 ? dh - 360 : (dh < -180 ? dh + 360 : dh)
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * .pi / 180)

        let lBarp = (l1 + l2) / 2
        let cBarp = (c1p + c2p) / 2
        var hBarp = h1p + h2p
        if c1p * c2p != 0 {
            hBarp = abs(h1p - h2p) > 180 ? (h1p + h2p < 360 ? hBarp + 360 : hBarp - 360) / 2 : hBarp / 2
        }

        let t = 1 - 0.17 * cos((hBarp - 30) * .pi / 180) + 0.24 * cos((2 * hBarp) * .pi / 180)
            + 0.32 * cos((3 * hBarp + 6) * .pi / 180) - 0.20 * cos((4 * hBarp - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBarp - 275) / 25, 2))
        let rc = 2 * (pow(cBarp, 7) / (pow(cBarp, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + (0.015 * pow(lBarp - 50, 2)) / (20 + pow(lBarp - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarp
        let sh = 1 + 0.015 * cBarp * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc

        let termL = dLp / sl, termC = dCp / sc, termH = dHp / sh
        return (termL * termL + termC * termC + termH * termH + rt * termC * termH).squareRoot()
    }
}
