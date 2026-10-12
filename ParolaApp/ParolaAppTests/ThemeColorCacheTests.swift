import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("Theme color cache")
struct ThemeColorCacheTests {
    @Test("a dynamic color resolves to one NSColor however often it is read")
    func sameInstanceOnEveryRead() {
        let tint = ThemeColor.dynamic(light: RGBA(0.1, 0.2, 0.3), dark: RGBA(0.7, 0.8, 0.9))
        #expect(tint.nsColor === tint.nsColor)
        #expect(tint.color == tint.color)
    }

    @Test("different values stay different, and each still follows the appearance")
    func valuesStayApart() throws {
        let first = ThemeColor.dynamic(light: RGBA(1, 0, 0), dark: RGBA(0, 1, 0))
        let second = ThemeColor.dynamic(light: RGBA(0, 0, 1), dark: RGBA(0, 1, 0))
        #expect(first.nsColor !== second.nsColor)
        var light = NSColor.clear
        var dark = NSColor.clear
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance { light = first.nsColor.usingColorSpace(.sRGB) ?? .clear }
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance { dark = first.nsColor.usingColorSpace(.sRGB) ?? .clear }
        #expect(light.redComponent == 1)
        #expect(dark.greenComponent == 1)
    }
}
