import SwiftUI
import ParolaCore

enum DS {
    enum Spacing {
        static let tight: CGFloat = 4
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

    enum Sidebar {
        static let minWidth: CGFloat = 280
        static let idealWidth: CGFloat = 320
    }

    /// Text-style-based scale so every label tracks the user's text-size / "Larger Text"
    /// accessibility setting. Pick the token whose default macOS point size is nearest the
    /// design value (largeTitle 26, title 22, title2 17, title3 15, headline/body 13,
    /// callout 12, subheadline 11, footnote/caption/caption2 10). Weight and design are baked
    /// into the token; the style still scales.
    enum Font {
        static let largeTitle = SwiftUI.Font.system(.largeTitle, design: .default)
        static let largeTitleRounded = SwiftUI.Font.system(.largeTitle, design: .rounded)

        static let title = SwiftUI.Font.system(.title, design: .default, weight: .semibold)
        static let titleRegular = SwiftUI.Font.system(.title, design: .default)
        static let titleRounded = SwiftUI.Font.system(.title, design: .rounded, weight: .semibold)

        static let title2 = SwiftUI.Font.system(.title2, design: .default, weight: .semibold)
        static let title2Regular = SwiftUI.Font.system(.title2, design: .default)

        static let title3 = SwiftUI.Font.system(.title3, design: .default, weight: .semibold)
        static let title3Regular = SwiftUI.Font.system(.title3, design: .default)
        static let title3Medium = SwiftUI.Font.system(.title3, design: .default, weight: .medium)
        static let title3Bold = SwiftUI.Font.system(.title3, design: .default, weight: .bold)

        static let heading = SwiftUI.Font.system(.headline, design: .default, weight: .semibold)

        static let body = SwiftUI.Font.system(.body, design: .default)
        static let bodyEmphasized = SwiftUI.Font.system(.body, design: .default, weight: .semibold)
        static let bodyMedium = SwiftUI.Font.system(.body, design: .default, weight: .medium)
        static let transcript = SwiftUI.Font.system(.body, design: .default).weight(.regular)

        static let bodyMono = SwiftUI.Font.system(.body, design: .monospaced)

        static let callout = SwiftUI.Font.system(.callout, design: .default)
        static let calloutEmphasized = SwiftUI.Font.system(.callout, design: .default, weight: .semibold)
        static let calloutMedium = SwiftUI.Font.system(.callout, design: .default, weight: .medium)
        static let calloutMono = SwiftUI.Font.system(.callout, design: .monospaced)
        static let calloutMonoEmphasized = SwiftUI.Font.system(.callout, design: .monospaced, weight: .semibold)

        static let subheadline = SwiftUI.Font.system(.subheadline, design: .default)
        static let subheadlineEmphasized = SwiftUI.Font.system(.subheadline, design: .default, weight: .semibold)
        static let subheadlineMedium = SwiftUI.Font.system(.subheadline, design: .default, weight: .medium)
        static let subheadlineBold = SwiftUI.Font.system(.subheadline, design: .default, weight: .bold)
        static let subheadlineMono = SwiftUI.Font.system(.subheadline, design: .monospaced)

        static let caption = SwiftUI.Font.system(.caption, design: .default)
        static let captionEmphasized = SwiftUI.Font.system(.caption, design: .default, weight: .semibold)
        static let captionMedium = SwiftUI.Font.system(.caption, design: .default, weight: .medium)
        static let captionMono = SwiftUI.Font.system(.caption, design: .monospaced)
        static let captionMonoEmphasized = SwiftUI.Font.system(.caption, design: .monospaced, weight: .semibold)

        static let caption2 = SwiftUI.Font.system(.caption2, design: .default)
        static let caption2Emphasized = SwiftUI.Font.system(.caption2, design: .default, weight: .semibold)
        static let caption2Medium = SwiftUI.Font.system(.caption2, design: .default, weight: .medium)
        static let caption2Bold = SwiftUI.Font.system(.caption2, design: .default, weight: .bold)
        static let caption2Mono = SwiftUI.Font.system(.caption2, design: .monospaced)
        static let caption2MonoEmphasized = SwiftUI.Font.system(.caption2, design: .monospaced, weight: .semibold)

        static let timer = SwiftUI.Font.system(.title, design: .monospaced).weight(.light)
    }

    /// The active palette every element color funnels through. AppModel.applyTheme() sets it on
    /// the main actor; view bodies read it on the main actor. nonisolated(unsafe) is safe because
    /// ThemePalette is a Sendable value and access is main-actor in practice.
    nonisolated(unsafe) static var theme: ThemePalette = ThemePreset.terracotta.palette

    enum Color {
        static var accent: SwiftUI.Color { DS.theme.accent.color }
        static var highlight: SwiftUI.Color { DS.theme.highlight.color }
        static var primaryText: SwiftUI.Color { DS.theme.textPrimary.color }
        static var secondaryText: SwiftUI.Color { DS.theme.textSecondary.color }
        static var surface: SwiftUI.Color { DS.theme.surface.color }
        static var surfaceElevated: SwiftUI.Color { DS.theme.surfaceElevated.color }
        static var separator: SwiftUI.Color { DS.theme.divider.color }
        static var danger: SwiftUI.Color { DS.theme.danger.color }

        /// A legible foreground for text/glyphs drawn on top of `accent`: near-black on light
        /// accents (Amber, Mint, custom), white on dark ones. Resolves per appearance.
        static var onAccent: SwiftUI.Color { DS.theme.accent.legibleForeground }
    }

    enum Palette {
        static var canvas: SwiftUI.Color { DS.theme.canvas.color }
        static var surface: SwiftUI.Color { DS.theme.surface.color }
        static var surfaceElevated: SwiftUI.Color { DS.theme.surfaceElevated.color }
        static var surfaceHover: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.06) }
        static var subtleFill: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.06) }
        static var divider: SwiftUI.Color { DS.theme.divider.color }
        static var pillFill: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.08) }
        static var pillFillHover: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.14) }
        static var success: SwiftUI.Color { DS.theme.success.color }
        static var warning: SwiftUI.Color { DS.theme.warning.color }
    }

    /// Traffic-light tint shared by every confidence indicator (segment stripes + the overall dot).
    static func confidenceColor(for bucket: SegmentConfidence.Bucket) -> SwiftUI.Color {
        switch bucket {
        case .high:   return Palette.success
        case .medium: return Palette.warning
        case .low:    return Color.danger
        }
    }

    static let speakerPalette: [SwiftUI.Color] = [
        SwiftUI.Color(red: 0.30, green: 0.45, blue: 0.68),  // dusty blue
        SwiftUI.Color(red: 0.62, green: 0.42, blue: 0.30),  // warm tan
        SwiftUI.Color(red: 0.42, green: 0.52, blue: 0.36),  // sage
        SwiftUI.Color(red: 0.58, green: 0.38, blue: 0.52),  // mauve
        SwiftUI.Color(red: 0.46, green: 0.50, blue: 0.58),  // slate
        SwiftUI.Color(red: 0.66, green: 0.50, blue: 0.34),  // ochre
        SwiftUI.Color(red: 0.36, green: 0.50, blue: 0.50),  // teal-grey
    ]

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

    static func formatBytes(_ bytes: Int) -> String {
        Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
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

    func inspectorPanel() -> some View {
        background(DS.Palette.surface)
            .overlay(alignment: .leading) {
                DS.Palette.divider.frame(width: 1)
            }
    }
}
