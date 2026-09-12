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
    }

    enum Radius {
        static let small: CGFloat = 6
        static let regular: CGFloat = 12
        static let large: CGFloat = 14
    }

    /// Durations for chrome that moves on its own; every site pairs these with `accessibilityReduceMotion`.
    enum Motion {
        static let route = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let rowState = SwiftUI.Animation.easeOut(duration: 0.12)
        static let listRows = SwiftUI.Animation.easeOut(duration: 0.22)
        static let progress = SwiftUI.Animation.easeOut(duration: 0.5)
        static let resize = SwiftUI.Animation.easeOut(duration: 0.25)
    }

    enum Size {
        static let progressBarHeight: CGFloat = 6
        static let liveTranscriptMinHeight: CGFloat = 180
    }

    /// The app's type scale. Sizes are ours rather than the system text styles, so a tier means the
    /// same thing on every surface: `display` 28 semibold for empty-state titles and big numbers,
    /// `title` 22 semibold for page and sheet titles, `heading` 15 semibold for section and card
    /// titles, `body` 13 with `bodyStrong` 13 medium for row titles, `secondary` 12 for every
    /// meta line, `caption` 11 medium for uppercase captions, badges and chips, `mono` 12 for
    /// timecodes, sizes and counts, `transcript` 15 (`transcriptCompact` 13) for reading text, and
    /// `timer` 22 for a live readout.
    enum Font {
        static let display = SwiftUI.Font.system(size: 28, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        static let secondary = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced).monospacedDigit()
        static let transcript = SwiftUI.Font.system(size: 15)
        static let transcriptCompact = SwiftUI.Font.system(size: 13)
        static let timer = SwiftUI.Font.system(size: 22, weight: .light, design: .monospaced)

        // MARK: - Legacy names, mapped onto the tiers above

        static let largeTitle = display
        static let largeTitleRounded = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
        static let titleRegular = SwiftUI.Font.system(size: 22)
        static let titleRounded = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)

        static let title2 = heading
        static let title2Regular = SwiftUI.Font.system(size: 15)
        static let title3 = heading
        static let title3Regular = SwiftUI.Font.system(size: 15)
        static let title3Medium = SwiftUI.Font.system(size: 15, weight: .medium)
        static let title3Bold = SwiftUI.Font.system(size: 15, weight: .bold)

        static let bodyEmphasized = bodyStrong
        static let bodyMedium = bodyStrong
        static let bodyMono = mono

        static let callout = secondary
        static let calloutEmphasized = bodyStrong
        static let calloutMedium = bodyStrong
        static let calloutMono = mono
        static let calloutMonoEmphasized = SwiftUI.Font.system(size: 12, weight: .semibold, design: .monospaced).monospacedDigit()

        static let subheadline = secondary
        static let subheadlineEmphasized = bodyStrong
        static let subheadlineMedium = bodyStrong
        static let subheadlineBold = SwiftUI.Font.system(size: 13, weight: .bold)
        static let subheadlineMono = mono

        static let captionEmphasized = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let captionMedium = caption
        static let captionMono = mono
        static let captionMonoEmphasized = calloutMonoEmphasized

        static let caption2 = caption
        static let caption2Emphasized = captionEmphasized
        static let caption2Medium = caption
        static let caption2Bold = SwiftUI.Font.system(size: 11, weight: .bold)
        static let caption2Mono = mono
        static let caption2MonoEmphasized = calloutMonoEmphasized
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
    nonisolated(unsafe) private static var activeTheme = ThemePreset.terracotta.palette
    nonisolated(unsafe) private static var resolved = Resolved(ThemePreset.terracotta.palette)

    /// One instance per palette, so repeated reads compare equal and SwiftUI can skip redraws; a dynamic NSColor re-runs its provider per draw, so the cached instance still follows the appearance.
    private struct Resolved {
        let accent: SwiftUI.Color
        let accentText: SwiftUI.Color
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
            accentText = palette.accentText.color
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
            onAccent = palette.accent.legibleForeground
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
        static var highlight: SwiftUI.Color { DS.resolved.highlight }
        static var primaryText: SwiftUI.Color { DS.resolved.primaryText }
        static var secondaryText: SwiftUI.Color { DS.resolved.secondaryText }
        static var surface: SwiftUI.Color { DS.resolved.surface }
        static var surfaceElevated: SwiftUI.Color { DS.resolved.surfaceElevated }
        static var separator: SwiftUI.Color { DS.resolved.divider }
        static var danger: SwiftUI.Color { DS.resolved.danger }

        /// A legible foreground for text/glyphs drawn on top of `accent`: near-black on light
        /// accents (Amber, Mint, custom), white on dark ones. Resolves per appearance.
        static var onAccent: SwiftUI.Color { DS.resolved.onAccent }

        /// The accent as small text on a surface, darkened or lightened until it clears AA.
        static var accentText: SwiftUI.Color { DS.resolved.accentText }

        /// The soft accent fill a live readout sits on; `accentText` is legible on it.
        static var accentWash: SwiftUI.Color { DS.resolved.accentWash }

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
        .dynamic(light: RGBA(0.346, 0.428, 0.297), dark: RGBA(0.568, 0.662, 0.512)),  // sage
        .dynamic(light: RGBA(0.529, 0.347, 0.475), dark: RGBA(0.733, 0.593, 0.691)),  // mauve
        .dynamic(light: RGBA(0.370, 0.406, 0.476), dark: RGBA(0.606, 0.635, 0.694)),  // slate
        .dynamic(light: RGBA(0.503, 0.381, 0.259), dark: RGBA(0.736, 0.612, 0.488)),  // ochre
        .dynamic(light: RGBA(0.307, 0.426, 0.426), dark: RGBA(0.526, 0.659, 0.659)),  // teal-grey
    ]

    static let speakerPalette: [SwiftUI.Color] = speakerTints.map(\.color)

    /// The one symbol table for entry categories: sidebar, library empty states and Recently Deleted.
    static func categorySymbol(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "text.alignleft"
        case .meeting: return "person.2"
        case .dictation: return "text.cursor"
        }
    }

    static func categoryTint(for category: EntryCategory) -> SwiftUI.Color {
        switch category {
        case .transcription: return SwiftUI.Color(red: 0.20, green: 0.62, blue: 0.62)
        case .meeting: return SwiftUI.Color(red: 0.34, green: 0.62, blue: 0.36)
        case .dictation: return SwiftUI.Color(red: 0.82, green: 0.50, blue: 0.18)
        }
    }

    static func mediaTint(for kind: BatchMediaKind) -> SwiftUI.Color {
        switch kind {
        case .video: return SwiftUI.Color(red: 0.30, green: 0.62, blue: 0.42)
        case .audio: return SwiftUI.Color(red: 0.24, green: 0.62, blue: 0.66)
        }
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

    /// A live readout that must hold the accent on video — `onAccent` fill lands under AA on five of seven presets.
    func accentPill() -> some View {
        font(DS.Font.captionMono)
            .foregroundStyle(DS.Color.accentText)
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

    func pillStyle(bordered: Bool = true) -> some View {
        padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .background(Capsule(style: .continuous).fill(DS.Palette.pillFill))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Palette.divider, lineWidth: bordered ? 1 : 0)
            )
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
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
