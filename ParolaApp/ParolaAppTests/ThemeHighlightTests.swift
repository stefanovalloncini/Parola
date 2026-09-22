import Foundation
import Testing
@testable import Parola

@Suite("Theme highlight")
struct ThemeHighlightTests {
    @Test("vivid presets keep the accent as their highlight", arguments: [
        ThemePreset.slate, .terracotta, .blue, .teal, .sage, .indigo, .mint, .purple, .pink, .yellow,
    ])
    func vividPresetsHighlightEqualsAccent(_ preset: ThemePreset) {
        let palette = preset.palette
        #expect(palette.highlight == palette.accent)
    }

    @Test("the Mono preset swaps its grey accent for a legible highlight")
    func monoPresetGetsLegibleHighlight() throws {
        let palette = ThemePreset.graphite.palette
        #expect(palette.highlight != palette.accent)
        guard case .dynamic(let light, let dark) = palette.highlight else {
            Issue.record("expected a dynamic highlight color")
            return
        }
        #expect(light.chroma >= 0.15)
        #expect(dark.chroma >= 0.15)
    }

    /// Sage joins Mono on the other side of the floor: darkening its light value to clear AA costs it the chroma a tint needs.
    @Test("Mono and Sage cannot tint text")
    func greyAccentsCannotTint() {
        #expect(ThemePreset.graphite.palette.accentText.readsAsTint == false)
        #expect(ThemePreset.sage.palette.accentText.readsAsTint == false)
    }

    @Test(
        "a vivid accent can tint text",
        arguments: ThemePreset.allCases.filter { $0 != .graphite && $0 != .sage }
    )
    func vividAccentsReadAsATint(_ preset: ThemePreset) {
        #expect(preset.palette.accentText.readsAsTint)
    }

    @Test("chroma is near zero for greys and large for saturated colors")
    func chromaProxy() {
        #expect(RGBA(0.42, 0.43, 0.47).chroma < 0.15)
        #expect(RGBA(0.20, 0.49, 0.96).chroma > 0.5)
        #expect(RGBA(0.5, 0.5, 0.5).chroma == 0)
    }
}
