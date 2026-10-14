import AppKit
import SwiftUI
import ParolaCore

enum DS {
    enum Spacing {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let small: CGFloat = 8
        static let regular: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 36
        /// Leading for every transcript reading surface, so one line-height rule covers them all.
        static let transcriptLeading: CGFloat = 5
        /// The same rule for the compact tier, tighter so compact mode still buys the rows it promises.
        static let transcriptLeadingCompact: CGFloat = 3
    }

    enum Radius {
        static let small: CGFloat = 6
        static let regular: CGFloat = 12
        static let large: CGFloat = 14
        /// A kind's tile, in a row or on the shelf.
        static let tile: CGFloat = 8
    }

    /// Durations for chrome that moves on its own; every site pairs these with `accessibilityReduceMotion`.
    enum Motion {
        static let route = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let rowState = SwiftUI.Animation.easeOut(duration: 0.12)
        static let listRows = SwiftUI.Animation.easeOut(duration: 0.22)
        static let progress = SwiftUI.Animation.easeOut(duration: 0.5)
        static let resize = SwiftUI.Animation.easeOut(duration: 0.25)
        static let followSegment = SwiftUI.Animation.easeInOut(duration: 0.2)

        static func follow(reduceMotion: Bool) -> SwiftUI.Animation? { reduceMotion ? nil : followSegment }
    }

    /// One reading of "you can't press this", so two disabled controls never sit side by side at different weights.
    enum Opacity {
        static let disabled = 0.4
    }

    enum Size {
        static let progressBarHeight: CGFloat = 6
        static let liveTranscriptMinHeight: CGFloat = 180
        static let demoTranscriptMinHeight: CGFloat = 220
        static let readingWidth: CGFloat = 720
    }

    /// Letter-spacing for the display tiers; SwiftUI takes tracking as a view modifier, so the call site pairs the two.
    enum Tracking {
        static let wordmark: CGFloat = -1.5
        static let hero: CGFloat = -1.0
        static let display: CGFloat = -0.5
    }

    /// Sixteen fixed tiers, ours rather than the system text styles, so a tier means the same thing
    /// on every surface. Pick by role — page title, section heading, row title, meta line, caption.
    /// SF throughout, SF Rounded for the timer. The transcript reading surface can switch to New York:
    /// pass `serif:` to `transcript`, `transcriptCompact` or `transcriptEmphasis`.
    enum Font {
        /// The brand lockup on the first-run stage, nowhere else.
        static let wordmark = SwiftUI.Font.system(size: 56, weight: .bold)
        static let hero = SwiftUI.Font.system(size: 40, weight: .bold)
        static let display = SwiftUI.Font.system(size: 28, weight: .bold)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        /// One step above `heading`, so a sheet's title still leads the sections inside it.
        static let sheetTitle = SwiftUI.Font.system(size: 17, weight: .bold)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        static let secondary = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced).monospacedDigit()
        static let transcript = SwiftUI.Font.system(size: 17)
        static let transcriptCompact = SwiftUI.Font.system(size: 15)
        private static let serifTranscript = SwiftUI.Font.system(size: 17, design: .serif)
        private static let serifTranscriptCompact = SwiftUI.Font.system(size: 15, design: .serif)

        static func transcript(serif: Bool) -> SwiftUI.Font { serif ? serifTranscript : transcript }
        static func transcriptCompact(serif: Bool) -> SwiftUI.Font { serif ? serifTranscriptCompact : transcriptCompact }
        /// Derived so the karaoke word under the playhead follows the transcript face wherever it goes.
        static func transcriptEmphasis(serif: Bool) -> SwiftUI.Font { transcript(serif: serif).weight(.semibold) }
        static let excerpt = SwiftUI.Font.system(size: 14)
        static let timer = SwiftUI.Font.system(size: 22, weight: .light, design: .rounded).monospacedDigit()
    }

    /// The active palette every element color funnels through. AppModel.applyTheme() sets it on the main actor.
    static var theme: ThemePalette {
        get { activeTheme }
        set {
            guard newValue != activeTheme else { return }
            activeTheme = newValue
            resolved = Resolved(newValue)
        }
    }

    // nonisolated(unsafe): both slots are written and read on the main actor only — work that runs off it takes the colors it needs as parameters.
    nonisolated(unsafe) private static var activeTheme = ThemePreset.defaultPreset.palette
    nonisolated(unsafe) private static var resolved = Resolved(ThemePreset.defaultPreset.palette)

    /// One instance per palette, so repeated reads compare equal and SwiftUI can skip redraws; a dynamic NSColor re-runs its provider per draw, so the cached instance still follows the appearance.
    private struct Resolved {
        let accent: SwiftUI.Color
        let accentFill: SwiftUI.Color
        let accentInk: SwiftUI.Color
        let accentWash: SwiftUI.Color
        let dangerText: SwiftUI.Color
        let warningText: SwiftUI.Color
        let dangerOnDark: SwiftUI.Color
        let successText: SwiftUI.Color
        let highlight: SwiftUI.Color
        let primaryText: SwiftUI.Color
        let secondaryText: SwiftUI.Color
        let surface: SwiftUI.Color
        let surfaceElevated: SwiftUI.Color
        let divider: SwiftUI.Color
        let danger: SwiftUI.Color
        let onAccent: SwiftUI.Color
        let canvas: SwiftUI.Color
        let success: SwiftUI.Color
        let warning: SwiftUI.Color
        let warningChip: (fill: SwiftUI.Color, text: SwiftUI.Color)
        let successChip: (fill: SwiftUI.Color, text: SwiftUI.Color)
        let neutralChip: (fill: SwiftUI.Color, text: SwiftUI.Color)

        init(_ palette: ThemePalette) {
            accent = palette.accent.color
            accentFill = palette.accentFill.color
            accentInk = palette.accentInk.color
            accentWash = palette.accentWash.color
            dangerText = palette.dangerText.color
            warningText = palette.warningText.color
            dangerOnDark = palette.dangerOnDark.color
            successText = palette.successText.color
            highlight = palette.highlight.color
            primaryText = palette.textPrimary.color
            secondaryText = palette.textSecondary.color
            surface = palette.surface.color
            surfaceElevated = palette.surfaceElevated.color
            divider = palette.divider.color
            danger = palette.danger.color
            onAccent = palette.onAccent.color
            canvas = palette.canvas.color
            success = palette.success.color
            warning = palette.warning.color
            let chips = [palette.warning, palette.success, palette.textSecondary].map {
                let pair = palette.statusChip($0)
                return (fill: pair.fill.color, text: pair.text.color)
            }
            warningChip = chips[0]
            successChip = chips[1]
            neutralChip = chips[2]
        }
    }

    enum Color {
        static var accent: SwiftUI.Color { DS.resolved.accent }

        /// The opaque fill every surface draws under `onAccent` text or glyphs; solved per preset and appearance so `onAccent` clears AA on it.
        static var accentFill: SwiftUI.Color { DS.resolved.accentFill }

        static var highlight: SwiftUI.Color { DS.resolved.highlight }
        static var primaryText: SwiftUI.Color { DS.resolved.primaryText }
        static var secondaryText: SwiftUI.Color { DS.resolved.secondaryText }
        static var surface: SwiftUI.Color { DS.resolved.surface }
        static var surfaceElevated: SwiftUI.Color { DS.resolved.surfaceElevated }
        static var separator: SwiftUI.Color { DS.resolved.divider }
        static var danger: SwiftUI.Color { DS.resolved.danger }

        /// The ink `accentFill` was solved for — white unless that cost too much of the accent's value.
        static var onAccent: SwiftUI.Color { DS.resolved.onAccent }

        /// The second text tier on an accent fill — the same ink as `onAccent`, at full strength: macOS ranks a selected row's secondary text by weight and size, not by dimming it.
        static var onAccentSecondary: SwiftUI.Color { DS.resolved.onAccent }

        /// The backing a badge, tile or glyph keeps when it sits on an accent fill.
        static var onAccentWash: SwiftUI.Color { DS.resolved.onAccent.opacity(0.18) }

        /// The accent as small text or a glyph set directly on a surface, darkened or lightened until it clears AA.
        static var accentInk: SwiftUI.Color { DS.resolved.accentInk }

        /// The soft accent fill a live readout sits on; `accentInk` is legible on it.
        static var accentWash: SwiftUI.Color { DS.resolved.accentWash }

        /// What a selected content row or card carries, where a solid accent would swallow its text.
        static var selectionWash: SwiftUI.Color { DS.resolved.accent.opacity(selectionWashTint) }

        /// The wash's strength on its own, for the contrast tests that blend it themselves.
        static let selectionWashTint = 0.12

        /// What a chosen sidebar row, menu row or preset chip is filled with; `onAccent` is its ink.
        static var selectionProminent: SwiftUI.Color { DS.resolved.accentFill }

        /// `danger` / `success` as small text, adjusted until they clear AA on the card fill.
        static var dangerText: SwiftUI.Color { DS.resolved.dangerText }
        static var successText: SwiftUI.Color { DS.resolved.successText }
        static var warningText: SwiftUI.Color { DS.resolved.warningText }

        /// `dangerText` for chrome drawn on its own dark scrim rather than on an app surface.
        static var dangerOnDark: SwiftUI.Color { DS.resolved.dangerOnDark }

        /// A status chip on a card: its soft fill and the label colour that clears AA on that fill.
        static var warningChip: (fill: SwiftUI.Color, text: SwiftUI.Color) { DS.resolved.warningChip }
        static var successChip: (fill: SwiftUI.Color, text: SwiftUI.Color) { DS.resolved.successChip }
        static var neutralChip: (fill: SwiftUI.Color, text: SwiftUI.Color) { DS.resolved.neutralChip }
    }

    /// One outline symbol per action, wherever the action is offered.
    enum Symbol {
        static let openFiles = "folder"
        static let microphone = "mic"
        static let systemAudio = "speaker.wave.2"
    }

    enum Palette {
        static var canvas: SwiftUI.Color { DS.resolved.canvas }
        static var surface: SwiftUI.Color { DS.resolved.surface }
        static var surfaceElevated: SwiftUI.Color { DS.resolved.surfaceElevated }
        static let surfaceHover = SwiftUI.Color.primary.opacity(0.06)
        static let subtleFill = SwiftUI.Color.primary.opacity(0.06)
        static var divider: SwiftUI.Color { DS.resolved.divider }
        static let pillFill = SwiftUI.Color.primary.opacity(0.08)
        /// What AppKit paints behind a text field, so ours sit at the same depth as the system ones.
        static let fieldFill = SwiftUI.Color(nsColor: .textBackgroundColor)
        static let pillFillHover = SwiftUI.Color.primary.opacity(0.14)
        static var success: SwiftUI.Color { DS.resolved.success }
        static var warning: SwiftUI.Color { DS.resolved.warning }
    }

    /// Traffic-light tint shared by every confidence indicator (segment stripes + the overall dot).
    static func confidenceColor(for bucket: SegmentConfidence.Bucket) -> SwiftUI.Color {
        switch bucket {
        case .high:   return Palette.success
        case .medium: return Palette.warning
        case .low:    return Color.danger
        }
    }

    /// One pair per hue, each clearing 5.0 on `surfaceElevated` and 3.2-4.7 on the segment card — see `SpeakerPaletteTests`.
    static let speakerTints: [ThemeColor] = [
        .dynamic(light: RGBA(0.272, 0.407, 0.616), dark: RGBA(0.538, 0.640, 0.796)),  // dusty blue
        .dynamic(light: RGBA(0.539, 0.365, 0.261), dark: RGBA(0.761, 0.601, 0.506)),  // warm tan
        .dynamic(light: RGBA(0.067, 0.439, 0.561), dark: RGBA(0.451, 0.663, 0.765)),  // steel blue
        .dynamic(light: RGBA(0.529, 0.347, 0.475), dark: RGBA(0.733, 0.593, 0.691)),  // mauve
        .dynamic(light: RGBA(0.370, 0.406, 0.476), dark: RGBA(0.606, 0.635, 0.694)),  // slate
        .dynamic(light: RGBA(0.503, 0.381, 0.259), dark: RGBA(0.736, 0.612, 0.488)),  // ochre
        .dynamic(light: RGBA(0.307, 0.426, 0.426), dark: RGBA(0.526, 0.659, 0.659)),  // teal-grey
    ]

    static let speakerPalette: [SwiftUI.Color] = speakerTints.map(\.color)

    /// A `List` fills a selected row with the accent only while it holds focus; anywhere else the selection is a grey wash.
    static func onAccent(isSelected: Bool, prominence: BackgroundProminence) -> Bool {
        isSelected && prominence == .increased
    }

    /// The one symbol table for entry categories: sidebar, library empty states and Recently Deleted.
    static func categorySymbol(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "text.alignleft"
        case .meeting: return "person.2"
        case .dictation: return "keyboard"
        }
    }

    static func categoryTint(for category: EntryCategory) -> SwiftUI.Color {
        switch category {
        case .transcription: return SwiftUI.Color(red: 0.20, green: 0.62, blue: 0.62)
        case .meeting: return SwiftUI.Color(red: 0.34, green: 0.62, blue: 0.36)
        case .dictation: return SwiftUI.Color(red: 0.82, green: 0.50, blue: 0.18)
        }
    }

    /// One system colour per Settings sidebar group, as System Settings tints its tiles; never red, which means "recording now".
    static func settingsGroupTint(for groupID: String) -> SwiftUI.Color {
        switch groupID {
        case "start": return .gray
        case "capture": return .indigo
        case "dictation": return .orange
        case "sources": return .blue
        case "transcription": return .teal
        case "export": return .green
        case "ai": return .purple
        case "automation": return .cyan
        default: return .gray
        }
    }

    static func mediaTint(for kind: BatchMediaKind) -> SwiftUI.Color {
        switch kind {
        case .video: return SwiftUI.Color(red: 0.30, green: 0.62, blue: 0.42)
        case .audio: return SwiftUI.Color(red: 0.24, green: 0.62, blue: 0.66)
        }
    }

    /// The solid tile a row's kind leads with: this colour at its foot, lightened by `highlight` at its top. A white glyph clears 3:1 on both ends in both appearances (`KindTileTests`).
    enum KindTile {
        static let highlight = 0.14

        /// The lighter top of the tile, blended in sRGB like the contrast test reads it.
        static func top(of foot: ThemeColor) -> ThemeColor {
            guard case .dynamic(let light, let dark) = foot else { return foot }
            return .dynamic(
                light: light.blended(toward: .white, amount: highlight),
                dark: dark.blended(toward: .white, amount: highlight)
            )
        }
        static let audio = ThemeColor.dynamic(light: RGBA(0.14, 0.56, 0.56), dark: RGBA(0.12, 0.52, 0.54))
        static let meeting = ThemeColor.dynamic(light: RGBA(0.31, 0.36, 0.82), dark: RGBA(0.40, 0.44, 0.90))
        static let dictation = ThemeColor.dynamic(light: RGBA(0.74, 0.42, 0.14), dark: RGBA(0.72, 0.41, 0.14))
        static let video = ThemeColor.dynamic(light: RGBA(0.55, 0.32, 0.80), dark: RGBA(0.60, 0.38, 0.85))
        static let web = ThemeColor.dynamic(light: RGBA(0.20, 0.50, 0.78), dark: RGBA(0.22, 0.50, 0.80))
    }

    /// A label assigned to a person wears that person's colour; an unassigned one keeps its hash.
    static func speakerColor(for label: String, colorIndex: Int?) -> SwiftUI.Color {
        guard let colorIndex, speakerPalette.indices.contains(colorIndex) else {
            return speakerColor(for: label)
        }
        return speakerPalette[colorIndex]
    }

    static func speakerColor(for label: String) -> SwiftUI.Color {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in key.unicodeScalars {
            hash = (hash ^ UInt64(scalar.value)) &* 0x100000001b3
        }
        let idx = Int(hash % UInt64(speakerPalette.count))
        return speakerPalette[idx]
    }
}

extension View {
    func cardBackground(
        radius: CGFloat = DS.Radius.regular,
        bordered: Bool = true
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DS.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(DS.Palette.divider, lineWidth: bordered ? 1 : 0)
        )
    }

    /// A live readout that must hold the accent on video: a soft wash rather than a solid pill.
    func accentPill(font: SwiftUI.Font = DS.Font.mono) -> some View {
        self.font(font)
            .foregroundStyle(DS.Color.accentInk)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.hair)
            .background(Capsule(style: .continuous).fill(DS.Color.accentWash))
    }

    /// A text field's border and focus ring, drawn by us — AppKit's own ring ignores the palette.
    func fieldChrome(focused: Bool) -> some View {
        padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.snug)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Palette.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(focused ? DS.Color.accent : DS.Palette.divider, lineWidth: focused ? 2 : 1)
            )
    }

    /// Secondary chrome (inspector, media bar). A material, not a token fill, so it keeps the hue of
    /// the window materials it abuts instead of reading as a detached neutral slab.
    func chromeSurface() -> some View {
        background(.regularMaterial)
    }

    func inspectorPanel() -> some View {
        background(DS.Palette.surface)
            .overlay(alignment: .leading) {
                DS.Palette.divider.frame(width: 1)
            }
    }
}
