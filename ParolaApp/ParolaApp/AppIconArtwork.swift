import AppKit
import CoreGraphics

/// The app icon's drawing, shared by `scripts/build-icon.swift` (which renders the sage brand icon
/// into the asset catalog) and the introduction's `BrandWaveform`. Both compile this file, so the
/// waveform can never drift between the Finder icon and the intro screen.
enum AppIconArtwork {
    static var brandBackground: NSColor { NSColor(srgbRed: 0.42, green: 0.54, blue: 0.42, alpha: 1) }
    static var brandForeground: NSColor { NSColor(srgbRed: 0.99, green: 0.95, blue: 0.90, alpha: 1) }

    static let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16.png",       16),
        ("icon_16x16@2x.png",    32),
        ("icon_32x32.png",       32),
        ("icon_32x32@2x.png",    64),
        ("icon_128x128.png",    128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png",    256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png",    512),
        ("icon_512x512@2x.png", 1024),
    ]

    /// Bar heights as fractions of the waveform's height; `BrandWaveform` draws the same nine, so the Dock icon and the introduction can't drift apart.
    static let barFractions: [CGFloat] = [0.32, 0.62, 0.84, 0.50, 0.92, 0.50, 0.84, 0.62, 0.32]

    static func draw(into context: CGContext, size: CGFloat, background: NSColor, foreground: NSColor) {
        // Apple's macOS icon grid insets the rounded square by 100/1024 of the canvas per side.
        let inset = size * 100 / 1024
        let artworkSide = size - inset * 2
        let rect = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
        context.saveGState()

        // Background with macOS-style continuous corner radius (~22% of side).
        let cornerRadius = artworkSide * 0.22
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.setFillColor(background.cgColor)
        context.fillPath()

        let bars = barFractions
        let barCount = CGFloat(bars.count)
        let usableWidth = artworkSide * 0.56
        let usableHeight = artworkSide * 0.72
        let spacing = usableWidth / (barCount * 2)
        let barWidth = (usableWidth - spacing * (barCount - 1)) / barCount
        let originX = inset + (artworkSide - usableWidth) / 2
        let centerY = size / 2

        context.setFillColor(foreground.cgColor)
        for (i, fraction) in bars.enumerated() {
            let height = max(barWidth * 1.1, usableHeight * fraction)
            let x = originX + CGFloat(i) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: barWidth / 2,
                cornerHeight: barWidth / 2,
                transform: nil
            )
            context.addPath(barPath)
            context.fillPath()
        }
        context.restoreGState()
    }

    static func cgImage(pixels: Int, background: NSColor, foreground: NSColor) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(into: context, size: CGFloat(pixels), background: background, foreground: foreground)
        return context.makeImage()
    }
}
