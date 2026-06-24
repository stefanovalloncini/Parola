import Foundation
import Testing
@testable import Parola

@Suite("Theme highlight")
struct ThemeHighlightTests {
    @Test("vivid presets keep the accent as their highlight", arguments: [
        ThemePreset.terracotta, .blue, .mint, .purple, .pink, .yellow,
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

    @Test("chroma is near zero for greys and large for saturated colors")
    func chromaProxy() {
        #expect(RGBA(0.42, 0.43, 0.47).chroma < 0.15)
        #expect(RGBA(0.20, 0.49, 0.96).chroma > 0.5)
        #expect(RGBA(0.5, 0.5, 0.5).chroma == 0)
    }
}
