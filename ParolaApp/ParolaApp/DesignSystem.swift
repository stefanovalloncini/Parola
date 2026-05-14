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
        static let accent = SwiftUI.Color.accentColor
        static let primaryText = SwiftUI.Color.primary
        static let secondaryText = SwiftUI.Color.secondary
        static let surface = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let surfaceElevated = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        static let danger = SwiftUI.Color.red
    }

    /// Speaker label tints. Desaturated so multiple speakers in one transcript don't
    /// look like a children's TV show.
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
}
