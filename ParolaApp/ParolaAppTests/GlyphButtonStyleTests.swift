import SwiftUI
import Testing
@testable import Parola

@Suite("Glyph button style")
@MainActor
struct GlyphButtonStyleTests {
    private func appearance(
        hovered: Bool = false,
        pressed: Bool = false,
        enabled: Bool = true,
        selectedFill: Color? = nil
    ) -> GlyphButtonAppearance {
        GlyphButtonAppearance(hovered: hovered, pressed: pressed, enabled: enabled, selectedFill: selectedFill)
    }

    private func resolvedOpacity(_ color: Color, _ scheme: ColorScheme) -> Float {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment).opacity
    }

    @Test("a glyph button nobody points at draws nothing behind its glyph")
    func restingIsBare() {
        let resting = appearance()
        #expect(resting.fill == Color.clear)
        #expect(resting.opacity == 1)
    }

    @Test("hover takes the wash a hovered row takes")
    func hoverMatchesTheRowWash() {
        let row = RowChromeAppearance(state: RowChromeState(selected: false, hovered: true), selection: .native)
        #expect(appearance(hovered: true).fill == row.fill)
        #expect(appearance(hovered: true).fill == DS.Palette.surfaceHover)
    }

    @Test("a press lights stronger than a hover, pointer inside or not", arguments: [ColorScheme.light, .dark])
    func pressOutranksHover(scheme: ColorScheme) {
        let hovered = appearance(hovered: true).fill
        for pointerInside in [true, false] {
            let pressed = appearance(hovered: pointerInside, pressed: true).fill
            #expect(pressed != hovered)
            #expect(resolvedOpacity(pressed, scheme) > resolvedOpacity(hovered, scheme))
        }
    }

    @Test("a disabled glyph dims and never washes")
    func disabledDimsWithoutWash() {
        for hovered in [true, false] {
            let disabled = appearance(hovered: hovered, enabled: false)
            #expect(disabled.fill == Color.clear)
            #expect(disabled.opacity == DS.Opacity.disabled)
        }
    }

    @Test("a toggle that is on keeps its fill under the pointer and the press")
    func selectedFillBeatsHoverAndPress() {
        let chosen = DS.Color.accent.opacity(0.15)
        for hovered in [true, false] {
            for pressed in [true, false] {
                #expect(appearance(hovered: hovered, pressed: pressed, selectedFill: chosen).fill == chosen)
            }
        }
    }

    @Test("the target defaults to 24 pt and a side sets both edges")
    func targetSize() {
        let standard = GlyphButtonStyle()
        #expect(standard.width == 24)
        #expect(standard.height == 24)
        #expect(standard.tinted == false)
        #expect(standard.selectedFill == nil)
        let transport = GlyphButtonStyle(side: 30)
        #expect(transport.width == 30)
        #expect(transport.height == 30)
    }

    @Test("the wash has the rows' corners")
    func washShapeMatchesTheRows() {
        #expect(GlyphButtonStyle.shape.cornerSize == CGSize(width: DS.Radius.small, height: DS.Radius.small))
        #expect(GlyphButtonStyle.shape.style == .continuous)
    }
}
