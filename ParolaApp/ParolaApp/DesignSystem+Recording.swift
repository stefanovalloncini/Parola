import SwiftUI

extension DS.Color {
    /// A take's Stop fill; white on it clears 4.5:1 in both appearances.
    static let recordingFillTheme = ThemeColor.dynamic(
        light: RGBA(0.769, 0.137, 0.165),
        dark: RGBA(0.839, 0.208, 0.184)
    )
    static let recordingFill = recordingFillTheme.color

    /// Text on the amber warning fill: over 9:1 in both appearances.
    static let warningBannerInkRGBA = RGBA(0.08, 0.08, 0.08)
    static let warningBannerInk = ThemeColor.uniform(warningBannerInkRGBA).color
}
