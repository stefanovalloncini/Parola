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

    enum Color {
        static var accent: SwiftUI.Color { AppAccent.current.color }
        static let primaryText = SwiftUI.Color.primary
        static let secondaryText = SwiftUI.Color.secondary
        static let surface = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let surfaceElevated = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        static let danger = SwiftUI.Color.red
    }

    enum Palette {
        static let canvas = SwiftUI.Color("CanvasColor")
        static let surface = SwiftUI.Color("SurfaceColor")
        static let surfaceElevated = SwiftUI.Color("SurfaceElevatedColor")
        static let surfaceHover = SwiftUI.Color.primary.opacity(0.06)
        static let divider = SwiftUI.Color("DividerColor")
        static let pillFill = SwiftUI.Color.primary.opacity(0.08)
        static let pillFillHover = SwiftUI.Color.primary.opacity(0.14)
        static let success = SwiftUI.Color(red: 0.32, green: 0.74, blue: 0.42)
        static let warning = SwiftUI.Color(red: 0.95, green: 0.66, blue: 0.20)
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
