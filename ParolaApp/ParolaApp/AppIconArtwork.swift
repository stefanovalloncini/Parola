import AppKit
import CoreGraphics

/// The app icon's drawing, shared by the running app (which tints it to the theme accent) and
/// `scripts/build-icon.swift` (which renders the sage brand icon into the asset catalog). Both
/// compile this file, so the waveform can never drift between the Finder icon and the Dock icon.
enum AppIconArtwork {
    enum Mark: Sendable {
        case pennino
        case waveform
    }

    struct Layout: Sendable {
        let mark: Mark
        let barWidth: CGFloat
        let spacing: CGFloat
        let height: CGFloat

        init(side: CGFloat, mark: Mark) {
            let count = CGFloat(AppIconArtwork.barFractions.count)
            let usableWidth = side * 0.56
            self.mark = mark
            spacing = usableWidth / (count * 2)
            barWidth = (usableWidth - spacing * (count - 1)) / count
            height = side * 0.72
        }

        var centerWidth: CGFloat { mark == .pennino ? barWidth * 4 : barWidth }

        var width: CGFloat {
            CGFloat(AppIconArtwork.barFractions.count - 1) * (barWidth + spacing) + centerWidth
        }

        func barHeight(_ fraction: CGFloat) -> CGFloat {
            max(barWidth * 1.1, height * fraction)
        }

        func centerOffset(of index: Int) -> CGFloat {
            let steps = abs(index - AppIconArtwork.centerIndex)
            guard steps > 0 else { return 0 }
            let offset = centerWidth / 2 + spacing + barWidth / 2 + CGFloat(steps - 1) * (barWidth + spacing)
            return index < AppIconArtwork.centerIndex ? -offset : offset
        }

        var nibFrame: CGRect {
            CGRect(x: -centerWidth / 2, y: -height * 0.465, width: centerWidth, height: height * 0.955)
        }
    }

    static var brandBackground: NSColor { NSColor(srgbRed: 0.42, green: 0.54, blue: 0.42, alpha: 1) }
    static var brandForeground: NSColor { NSColor(srgbRed: 0.99, green: 0.95, blue: 0.90, alpha: 1) }
    static var brandNib: NSColor { NSColor(srgbRed: 0.91, green: 0.72, blue: 0.38, alpha: 1) }

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
    static let centerIndex = barFractions.count / 2

    static func draw(
        into context: CGContext,
        size: CGFloat,
        background: NSColor,
        foreground: NSColor,
        nib: NSColor? = nil,
        mark: Mark = .pennino
    ) {
        // Apple's macOS icon grid insets the rounded square by 100/1024 of the canvas per side.
        let inset = size * 100 / 1024
        let artworkSide = size - inset * 2
        let rect = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
        context.saveGState()
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        // Background with macOS-style continuous corner radius (~22% of side).
        let cornerRadius = artworkSide * 0.22
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        fillBackground(path, in: rect, color: background, context: context)

        let layout = Layout(side: artworkSide, mark: mark)
        let center = CGPoint(x: size / 2, y: size / 2)
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 10 / 1024),
            blur: size * 22 / 1024,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(foreground.cgColor)
        for (i, fraction) in barFractions.enumerated() where mark == .waveform || i != centerIndex {
            let height = layout.barHeight(fraction)
            let x = center.x + layout.centerOffset(of: i) - layout.barWidth / 2
            let barRect = CGRect(x: x, y: center.y - height / 2, width: layout.barWidth, height: height)
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: layout.barWidth / 2,
                cornerHeight: layout.barWidth / 2,
                transform: nil
            )
            context.addPath(barPath)
            context.fillPath()
        }
        if mark == .pennino {
            let frame = layout.nibFrame.offsetBy(dx: center.x, dy: center.y)
            fillNib(nibPath(in: frame), color: nib ?? foreground, context: context)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func nibPath(in rect: CGRect) -> CGPath {
        let halfWidth = rect.width / 2
        let lower = halfWidth - rect.width * 0.086
        let corner = rect.width * 0.155
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x, y: rect.minY + y)
        }
        func point(_ x: CGFloat, along fraction: CGFloat) -> CGPoint {
            point(x, rect.height * fraction)
        }

        let outline = CGMutablePath()
        outline.move(to: point(-halfWidth + corner, 0))
        outline.addLine(to: point(halfWidth - corner, 0))
        outline.addQuadCurve(to: point(halfWidth, corner), control: point(halfWidth, 0))
        outline.addLine(to: point(halfWidth, along: 0.23))
        outline.addCurve(
            to: point(lower, along: 0.353),
            control1: point(halfWidth, along: 0.30),
            control2: point(lower, along: 0.30)
        )
        outline.addCurve(
            to: point(0, along: 1),
            control1: point(lower, along: 0.644),
            control2: point(lower * 0.18, along: 0.922)
        )
        outline.addCurve(
            to: point(-lower, along: 0.353),
            control1: point(-lower * 0.18, along: 0.922),
            control2: point(-lower, along: 0.644)
        )
        outline.addCurve(
            to: point(-halfWidth, along: 0.23),
            control1: point(-lower, along: 0.30),
            control2: point(-halfWidth, along: 0.30)
        )
        outline.addLine(to: point(-halfWidth, corner))
        outline.addQuadCurve(to: point(-halfWidth + corner, 0), control: point(-halfWidth, 0))
        outline.closeSubpath()

        let holeCenter = point(0, along: 0.42)
        let holeRadius = rect.width * 0.15
        let slitWidth = rect.width * 0.086
        let cutout = CGMutablePath()
        cutout.addEllipse(in: CGRect(
            x: holeCenter.x - holeRadius,
            y: holeCenter.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        ))
        cutout.addRect(CGRect(
            x: holeCenter.x - slitWidth / 2,
            y: holeCenter.y,
            width: slitWidth,
            height: rect.maxY - holeCenter.y + slitWidth
        ))
        return outline.subtracting(cutout)
    }

    private static func fillBackground(_ path: CGPath, in rect: CGRect, color: NSColor, context: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        let top = color.blended(withFraction: 0.1, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.1, of: .black) ?? color
        let glow = [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)]
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let shade = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                shade,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        if let light = CGGradient(colorsSpace: space, colors: glow.map(\.cgColor) as CFArray, locations: [0, 1]) {
            let source = CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.073)
            context.drawRadialGradient(
                light,
                startCenter: source,
                startRadius: 0,
                endCenter: source,
                endRadius: rect.height * 0.78,
                options: []
            )
        }
        context.restoreGState()
    }

    private static func fillNib(_ path: CGPath, color: NSColor, context: CGContext) {
        let bounds = path.boundingBoxOfPath
        let light = color.blended(withFraction: 0.28, of: .white) ?? color
        let dark = color.blended(withFraction: 0.16, of: .black) ?? color
        let stops = [light, color, color, dark].map(\.cgColor)
        guard let metal = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops as CFArray,
            locations: [0, 0.35, 0.6, 1]
        ) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            metal,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()
    }

    static func cgImage(
        pixels: Int,
        background: NSColor,
        foreground: NSColor,
        nib: NSColor? = nil,
        mark: Mark = .pennino
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(
            into: context,
            size: CGFloat(pixels),
            background: background,
            foreground: foreground,
            nib: nib,
            mark: mark
        )
        return context.makeImage()
    }
}
