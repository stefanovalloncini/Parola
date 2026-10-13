import Testing
@testable import Parola

@Suite("Kind tiles")
struct KindTileTests {
    private static let kinds: [(name: String, token: ThemeColor)] = [
        ("audio", DS.KindTile.audio), ("meeting", DS.KindTile.meeting), ("dictation", DS.KindTile.dictation),
        ("video", DS.KindTile.video), ("web", DS.KindTile.web),
    ]

    private func ends(of token: ThemeColor) -> [(String, RGBA)] {
        guard case .dynamic(let light, let dark) = token else { return [] }
        return [("light", light), ("dark", dark)].flatMap { appearance, foot in
            [("\(appearance) foot", foot), ("\(appearance) top", foot.blended(toward: .white, amount: DS.KindTile.highlight))]
        }
    }

    @Test("a white glyph clears 3:1 on both ends of every tile in both appearances")
    func whiteGlyphIsLegible() {
        for (name, token) in Self.kinds {
            let tones = ends(of: token)
            #expect(tones.count == 4, "\(name) has a light and a dark value")
            for (end, rgba) in tones {
                #expect(rgba.contrast(against: .white) >= 3, "\(name) \(end): \(rgba.contrast(against: .white))")
            }
        }
    }

    @Test("each kind keeps a hue of its own")
    func huesDiffer() {
        let feet = Self.kinds.compactMap { _, token -> RGBA? in
            guard case .dynamic(let light, _) = token else { return nil }
            return light
        }
        for (index, a) in feet.enumerated() {
            for b in feet[(index + 1)...] {
                let distance = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                #expect(distance > 0.25, "\(a) and \(b) are too close")
            }
        }
    }

    @Test("every source kind maps to its own tile")
    func everyKindHasATile() {
        let kinds: [EntrySourceKind] = [.meeting, .dictation, .audio, .video, .web]
        #expect(Set(kinds.map(\.tileFill)).count == kinds.count)
    }
}
