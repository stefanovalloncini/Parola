import AppKit
import SwiftUI

/// Tints the Dock icon (and the Cmd-Tab and window proxy icons that follow it) to the theme accent.
/// The icon on disk stays the sage brand color — this only applies while the app runs.
@MainActor
enum DockIcon {
    struct Colors: Equatable {
        var background: RGBA
        var foreground: RGBA
    }

    static let cream = RGBA(0.99, 0.95, 0.90)
    static let ink = RGBA(0.10, 0.10, 0.10)

    private static let repSizes = Set(AppIconArtwork.sizes.map(\.pixels)).sorted()
    private static var rendered: Colors?

    static func refresh() {
        guard let app = NSApp else { return }
        let colors = colors(accent: resolvedAccent(in: app.effectiveAppearance))
        guard rendered != colors else { return }
        rendered = colors
        app.applicationIconImage = image(colors)
    }

    static func colors(accent: RGBA) -> Colors {
        Colors(
            background: accent,
            foreground: accent.relativeLuminance > RGBA.darkForegroundLuminance ? ink : cream
        )
    }

    /// Resolving inside the effective appearance is what makes a `.dynamic` accent pick its
    /// light or dark variant — the same choice the window UI is making at that moment.
    private static func resolvedAccent(in appearance: NSAppearance) -> RGBA {
        var resolved = RGBA(0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            resolved = RGBA(DS.theme.accent.color)
        }
        return resolved
    }

    static func image(_ colors: Colors) -> NSImage {
        let largest = repSizes.last ?? 1024
        let image = NSImage(size: NSSize(width: largest, height: largest))
        for pixels in repSizes {
            guard let cgImage = AppIconArtwork.cgImage(
                pixels: pixels,
                background: colors.background.nsColor,
                foreground: colors.foreground.nsColor
            ) else { continue }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = NSSize(width: pixels, height: pixels)
            image.addRepresentation(rep)
        }
        return image
    }
}
