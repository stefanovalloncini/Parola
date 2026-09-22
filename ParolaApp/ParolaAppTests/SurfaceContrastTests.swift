import AppKit
import Foundation
import SwiftUI
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
            ("the header bar's language pill", palette.accentWash),
            ("the media bar's speed pill", palette.accentWash),
            ("the library row's note badge", palette.accentWash),
            ("the outline popover's timecodes", palette.surfaceElevated),
            ("the inspector's chapter timecodes", palette.surfaceElevated),
            ("the streaming caret", palette.surface),
            ("the About sheet's channel badge", palette.accentWash),
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

    /// The introduction's chosen engine card tints `surfaceElevated` with the selection wash and sets its detail line on that tint.
    @Test("the chosen engine card's detail clears AA on its accent tint", arguments: ThemePreset.allCases)
    func selectedEngineCardDetailContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let accent = try #require(Self.pair(palette.accent))
        let card = try #require(Self.pair(palette.surfaceElevated))
        let amount = DS.Color.selectionWashTint
        let tint = (
            light: card.light.blended(toward: accent.light, amount: amount),
            dark: card.dark.blended(toward: accent.dark, amount: amount)
        )

        let ink = try Self.primaryInk(palette)
        for (scheme, fill, label) in [("light", tint.light, ink.light), ("dark", tint.dark, ink.dark)] {
            let drawn = fill.blended(toward: label, amount: label.a)
            #expect(drawn.contrast(against: fill) >= Self.minimum, "\(preset.rawValue) \(scheme)")
        }
    }

    /// `textPrimary` is a system colour, so it only has a value inside a drawing appearance — and it carries alpha.
    private static func primaryInk(_ palette: ThemePalette) throws -> (light: RGBA, dark: RGBA) {
        var light = RGBA(0, 0, 0)
        var dark = RGBA(0, 0, 0)
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = RGBA(palette.textPrimary.color)
        }
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = RGBA(palette.textPrimary.color)
        }
        return (light, dark)
    }

    /// A disabled primary pill drops the accent for the neutral pair; `subtleFill` is `Color.primary` at 6% over the page.
    @Test("a disabled primary pill's label clears 3:1 on its neutral fill")
    func disabledPrimaryPillPair() throws {
        let label = try #require(Self.pair(ThemePalette.sharedNeutrals.textSecondary))
        let backdrops: [(String, ThemeColor)] = [
            ("surface", ThemePalette.sharedNeutrals.surface),
            ("surfaceElevated", ThemePalette.sharedNeutrals.surfaceElevated),
            ("canvas", ThemePalette.sharedNeutrals.canvas),
        ]
        for (name, backdrop) in backdrops {
            let behind = try #require(Self.pair(backdrop))
            let light = behind.light.blended(toward: RGBA(0, 0, 0), amount: 0.06)
            let dark = behind.dark.blended(toward: RGBA(1, 1, 1), amount: 0.06)
            #expect(label.light.contrast(against: light) >= 3, "light on \(name)")
            #expect(label.dark.contrast(against: dark) >= 3, "dark on \(name)")
        }
    }

    /// Every label set on the accent *fill* — pills, chips, selected rows, the rule filter, the captions mode chip.
    @Test("a label on the accent fill never reads worse than a hard-coded white one",
          arguments: ThemePreset.allCases)
    func onAccentBeatsAHardCodedWhite(preset: ThemePreset) throws {
        let white = RGBA(1, 1, 1)
        let accent = try #require(Self.pair(preset.palette.accent))
        for (scheme, fill) in [("light", accent.light), ("dark", accent.dark)] {
            #expect(
                fill.legibleForeground.contrast(against: fill) >= white.contrast(against: fill),
                "\(preset.rawValue) \(scheme)"
            )
        }
    }

    /// Amber is the pale accent white collapses on: 1.6:1 against the near-black the token picks instead.
    @Test("a pale accent takes a dark label")
    func paleAccentTakesADarkLabel() throws {
        let amber = try #require(Self.pair(ThemePreset.yellow.palette.accent)).light
        #expect(amber.legibleForeground.relativeLuminance < amber.relativeLuminance)
        #expect(amber.legibleForeground.contrast(against: amber) >= Self.minimum)
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

    @Test("red, green and amber as text clear AA on both surfaces, both schemes",
          arguments: ThemePreset.allCases)
    func statusTextContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        let surface = try #require(Self.pair(palette.surface))
        let card = try #require(Self.pair(palette.surfaceElevated))
        for (name, token) in [
            ("danger", palette.dangerText),
            ("success", palette.successText),
            ("warning", palette.warningText),
        ] {
            let text = try #require(Self.pair(token))
            #expect(text.light.contrast(against: surface.light) >= Self.minimum, "\(name) light on surface")
            #expect(text.light.contrast(against: card.light) >= Self.minimum, "\(name) light on card")
            #expect(text.dark.contrast(against: surface.dark) >= Self.minimum, "\(name) dark on surface")
            #expect(text.dark.contrast(against: card.dark) >= Self.minimum, "\(name) dark on card")
        }
    }

    /// The model card's chips paint their own wash of the status colour and set the label on it.
    @Test("a status chip's label clears AA on its own fill", arguments: ThemePreset.allCases)
    func statusChipContrast(preset: ThemePreset) throws {
        let palette = preset.palette
        for (name, tint) in [
            ("warning", palette.warning),
            ("success", palette.success),
            ("secondary", palette.textSecondary),
        ] {
            let chip = palette.statusChip(tint)
            let text = try #require(Self.pair(chip.text))
            let fill = try #require(Self.pair(chip.fill))
            #expect(text.light.contrast(against: fill.light) >= Self.minimum, "\(preset.rawValue) light, \(name)")
            #expect(text.dark.contrast(against: fill.dark) >= Self.minimum, "\(preset.rawValue) dark, \(name)")
        }
    }

    /// The trash page's section caption, its countdown and the bar under it read one bucket, in legible tokens.
    @MainActor
    @Test("an expiring item is urgent in every token the row draws it with")
    func recentlyDeletedBucketColours() {
        #expect(RecentlyDeletedCopy.ExpiryBucket.soon.countdownColor == DS.Color.dangerText)
        #expect(RecentlyDeletedCopy.ExpiryBucket.soon.barFill == DS.Color.dangerText)
        #expect(RecentlyDeletedCopy.ExpiryBucket.later.countdownColor == DS.Color.secondaryText)
        #expect(RecentlyDeletedCopy.ExpiryBucket.later.barFill == DS.Color.accent)
    }

    /// Selection alone is a grey wash; only an emphasized row is filled with the accent, and only there does the hue give way.
    @MainActor
    @Test("a row keeps its urgency until the accent is what it sits on")
    func recentlyDeletedUrgencyFollowsProminence() {
        let soon = RecentlyDeletedCopy.ExpiryBucket.soon
        let later = RecentlyDeletedCopy.ExpiryBucket.later

        #expect(soon.countdownColor(isSelected: false, prominence: .standard) == DS.Color.dangerText)
        #expect(soon.barFill(isSelected: false, prominence: .standard) == DS.Color.dangerText)
        #expect(later.barFill(isSelected: false, prominence: .increased) == DS.Color.accent)

        #expect(soon.countdownColor(isSelected: true, prominence: .standard) == DS.Color.dangerText)
        #expect(soon.barFill(isSelected: true, prominence: .standard) == DS.Color.dangerText)
        #expect(later.countdownColor(isSelected: true, prominence: .standard) == DS.Color.secondaryText)

        #expect(soon.countdownColor(isSelected: true, prominence: .increased) == DS.Color.onAccent)
        #expect(soon.barFill(isSelected: true, prominence: .increased) == DS.Color.onAccent)
        #expect(later.countdownColor(isSelected: true, prominence: .increased) == DS.Color.onAccent)
        #expect(later.barFill(isSelected: true, prominence: .increased) == DS.Color.onAccent)
    }

    /// The badge and the label chips of a selected row read the same rule the countdown and the bar do.
    @Test("a row's badge keeps its tint until the accent is what it sits on")
    func entryRowBadgeFollowsProminence() {
        #expect(!DS.onAccent(isSelected: false, prominence: .increased))
        #expect(!DS.onAccent(isSelected: true, prominence: .standard))
        #expect(DS.onAccent(isSelected: true, prominence: .increased))
    }

    /// The playhead word is the highlight on a card the same highlight washes at 10 % over `surface`; it is 15 pt semibold, so light mode answers to WCAG's large-bold 3:1.
    @MainActor
    @Test("the default accent's playhead word clears AA in dark and the large-bold floor in light")
    func playheadWordOnItsCard() throws {
        let tint = SegmentCard.currentCardTint
        let highlight = try #require(Self.pair(ThemePreset.defaultPreset.palette.highlight))
        let behind = try #require(Self.pair(ThemePreset.defaultPreset.palette.surface))
        let light = highlight.light.contrast(against: behind.light.blended(toward: highlight.light, amount: tint))
        let dark = highlight.dark.contrast(against: behind.dark.blended(toward: highlight.dark, amount: tint))

        #expect(dark >= Self.minimum, "dark playhead word: \(dark)")
        #expect(light >= 3, "light playhead word: \(light)")
    }

    /// A solid-accent selection is under text AA by ruling, so the inks below its title carry floors of their
    /// own: the subtitle tier on `accent × selectionProminentTint`, and the count badge set straight on it.
    @Test("the ink tiers on a chosen row each keep their floor")
    func inkTiersOnTheProminentFill() throws {
        let accent = try #require(Self.pair(ThemePreset.defaultPreset.palette.accent))
        let ground = try #require(Self.pair(ThemePalette.sharedNeutrals.surfaceElevated))
        for (scheme, behind, tint) in [
            ("light", ground.light, accent.light),
            ("dark", ground.dark, accent.dark),
        ] {
            let fill = behind.blended(toward: tint, amount: DS.Color.selectionProminentTint)
            let second = fill.blended(toward: tint.legibleForeground, amount: DS.Color.onAccentSecondaryTint)
            #expect(second.contrast(against: fill) >= 2.75, "\(scheme): \(second.contrast(against: fill))")

            // A chosen row's count badge has no pill of its own: the digit is set straight on the fill.
            let badge = tint.legibleForeground
            #expect(badge.contrast(against: fill) >= 3, "\(scheme) badge: \(badge.contrast(against: fill))")
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
