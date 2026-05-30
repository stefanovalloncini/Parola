import SwiftUI

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
        static let regular: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Sidebar {
        static let minWidth: CGFloat = 280
        static let idealWidth: CGFloat = 320
    }

    enum Font {
        static let title = SwiftUI.Font.system(.title2, design: .default, weight: .semibold)
        static let heading = SwiftUI.Font.system(.headline, design: .default, weight: .semibold)
        static let body = SwiftUI.Font.system(.body, design: .default)
        static let transcript = SwiftUI.Font.system(.body, design: .default).weight(.regular)
        static let caption = SwiftUI.Font.system(.caption, design: .default)
        static let captionMono = SwiftUI.Font.system(.caption, design: .monospaced)
        static let timer = SwiftUI.Font.system(size: 28, weight: .light, design: .monospaced)
    }

    /// The active palette every element color funnels through. AppModel.applyTheme() sets it on
    /// the main actor; view bodies read it on the main actor. nonisolated(unsafe) is safe because
    /// ThemePalette is a Sendable value and access is main-actor in practice.
    nonisolated(unsafe) static var theme: ThemePalette = ThemePreset.terracotta.palette

    enum Color {
        static var accent: SwiftUI.Color { DS.theme.accent.color }
        static var primaryText: SwiftUI.Color { DS.theme.textPrimary.color }
        static var secondaryText: SwiftUI.Color { DS.theme.textSecondary.color }
        static var surface: SwiftUI.Color { DS.theme.surface.color }
        static var surfaceElevated: SwiftUI.Color { DS.theme.surfaceElevated.color }
        static var separator: SwiftUI.Color { DS.theme.divider.color }
        static var danger: SwiftUI.Color { DS.theme.danger.color }
    }

    enum Palette {
        static var canvas: SwiftUI.Color { DS.theme.canvas.color }
        static var surface: SwiftUI.Color { DS.theme.surface.color }
        static var surfaceElevated: SwiftUI.Color { DS.theme.surfaceElevated.color }
        static var surfaceHover: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.06) }
        static var divider: SwiftUI.Color { DS.theme.divider.color }
        static var pillFill: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.08) }
        static var pillFillHover: SwiftUI.Color { SwiftUI.Color.primary.opacity(0.14) }
        static var success: SwiftUI.Color { DS.theme.success.color }
        static var warning: SwiftUI.Color { DS.theme.warning.color }
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

    static func speakerColor(for label: String) -> SwiftUI.Color {
        let digits = label.compactMap(\.wholeNumberValue)
        let idx = (digits.first ?? 0) % speakerPalette.count
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
