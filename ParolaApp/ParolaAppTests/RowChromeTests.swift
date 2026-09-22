import SwiftUI
import Testing
@testable import Parola

@Suite("Row chrome")
@MainActor
struct RowChromeTests {
    private let prominent = RowSelectionStyle.prominent(
        fill: DS.Color.accent.opacity(0.85),
        foreground: DS.Color.onAccent
    )
    private let wash = RowSelectionStyle.wash(
        fill: DS.Color.selectionWash,
        border: DS.Color.accent.opacity(0.35)
    )

    private func appearance(
        selected: Bool,
        hovered: Bool,
        _ selection: RowSelectionStyle
    ) -> RowChromeAppearance {
        RowChromeAppearance(
            state: RowChromeState(selected: selected, hovered: hovered),
            selection: selection
        )
    }

    @Test("a hovered row takes the one hover fill, whatever its selection style")
    func hoverFillIsShared() {
        for selection in [prominent, wash, .native] {
            let hovered = appearance(selected: false, hovered: true, selection)
            #expect(hovered.fill == DS.Palette.surfaceHover)
            #expect(hovered.border == nil)
            #expect(hovered.foreground == nil)
        }
    }

    @Test("a row nobody points at draws nothing")
    func restingRowIsClear() {
        for selection in [prominent, wash, .native] {
            #expect(appearance(selected: false, hovered: false, selection).fill == Color.clear)
        }
    }

    @Test("selection suppresses hover in every style")
    func selectionBeatsHover() {
        for selection in [prominent, wash, .native] {
            let pointed = appearance(selected: true, hovered: true, selection)
            #expect(pointed == appearance(selected: true, hovered: false, selection))
            #expect(pointed.fill != DS.Palette.surfaceHover)
        }
    }

    @Test("a prominent row carries its family's fill and foreground")
    func prominentCarriesItsPair() {
        let selected = appearance(selected: true, hovered: false, prominent)
        #expect(selected.fill == DS.Color.accent.opacity(0.85))
        #expect(selected.foreground == DS.Color.onAccent)
        #expect(selected.border == nil)
    }

    @Test("a washed row carries its fill and its outline")
    func washCarriesItsOutline() {
        let selected = appearance(selected: true, hovered: false, wash)
        #expect(selected.fill == DS.Color.selectionWash)
        #expect(selected.border == DS.Color.accent.opacity(0.35))
        #expect(selected.foreground == nil)
    }

    @Test("a wash without an outline draws none")
    func washWithoutBorder() {
        let selected = appearance(selected: true, hovered: false, .wash(fill: DS.Color.accentWash))
        #expect(selected.fill == DS.Color.accentWash)
        #expect(selected.border == nil)
    }

    @Test("a row in a List draws nothing of its own when selected")
    func nativeSelectionDrawsNothing() {
        let selected = appearance(selected: true, hovered: false, .native)
        #expect(selected.fill == Color.clear)
        #expect(selected.border == nil)
        #expect(selected.foreground == nil)
    }

    @Test("the selection wash is the accent at the shared strength")
    func selectionWashIsTheAccent() {
        #expect(DS.Color.selectionWash == DS.Color.accent.opacity(0.12))
    }

    @Test("a chosen popover row is a solid accent with a legible foreground")
    func popoverRowIsProminent() {
        let selected = appearance(selected: true, hovered: false, PillPopoverRow.selectionStyle)
        #expect(selected.fill == DS.Color.accent.opacity(0.85))
        #expect(selected.foreground == DS.Color.onAccent)
        #expect(selected.border == nil)
    }

    @Test("a popover row under the pointer takes the shared hover fill, not the accent")
    func popoverRowHoverIsShared() {
        let hovered = appearance(selected: false, hovered: true, PillPopoverRow.selectionStyle)
        #expect(hovered.fill == DS.Palette.surfaceHover)
        #expect(hovered.foreground == nil)
        #expect(appearance(selected: true, hovered: true, PillPopoverRow.selectionStyle)
            == appearance(selected: true, hovered: false, PillPopoverRow.selectionStyle))
    }

    @Test("the popover row and the sidebar row are chosen with the same fill")
    func popoverRowMatchesTheSidebar() {
        let popover = appearance(selected: true, hovered: false, PillPopoverRow.selectionStyle)
        let sidebar = appearance(selected: true, hovered: false, SidebarRowLabel.selectionStyle)
        #expect(popover.fill == sidebar.fill)
        // The sidebar's labels name their own onAccent tiers; the popover row lets the chrome paint the first one.
        #expect(sidebar.foreground == nil)
        #expect(popover.foreground == DS.Color.onAccent)
    }

    @Test("the find bar's toggle inks its glyph with the same token the popover row does")
    func findToggleCarriesTheLegibleInk() {
        let popover = appearance(selected: true, hovered: false, PillPopoverRow.selectionStyle)
        let toggle = appearance(selected: true, hovered: false, FindToggleButton.selectionStyle)
        #expect(FindToggleButton.ink(isOn: true) == popover.foreground)
        #expect(FindToggleButton.ink(isOn: false) != popover.foreground)
        // The toggle is a 22 pt glyph, not a row of text: it takes the accent at full strength.
        #expect(toggle.fill == DS.Color.accent)
    }

    @Test("a row in a List animates its hover, never the selection the List paints")
    func nativeSelectionIsNotAnimated() {
        let pointedAndSelected = RowChromeState(selected: true, hovered: true)
        #expect(
            pointedAndSelected.animationValue(for: .native)
                == RowChromeState(selected: false, hovered: true)
        )
        #expect(
            RowChromeState(selected: true, hovered: false).animationValue(for: .native)
                == RowChromeState(selected: false, hovered: false)
        )
        for selection in [prominent, wash] {
            #expect(pointedAndSelected.animationValue(for: selection) == pointedAndSelected)
        }
    }

    @Test("reduce motion leaves the row state unanimated")
    func reduceMotionSkipsTheAnimation() {
        #expect(RowChromeAppearance.animation(reduceMotion: true) == nil)
        #expect(RowChromeAppearance.animation(reduceMotion: false) == DS.Motion.rowState)
    }
}
