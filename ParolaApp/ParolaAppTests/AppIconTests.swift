import AppKit
import Foundation
import Testing
@testable import Parola

@Suite("App icon")
struct AppIconTests {

    private func sample(_ rep: NSBitmapImageRep, xFraction: Double, yFraction: Double) -> RGBA {
        let x = Int(Double(rep.pixelsWide) * xFraction)
        let y = Int(Double(rep.pixelsHigh) * yFraction)
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            Issue.record("no pixel at \(x),\(y)")
            return RGBA(0, 0, 0)
        }
        return RGBA(
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
            Double(color.alphaComponent)
        )
    }

    private func pixel(_ image: CGImage, xFraction: Double, yFraction: Double) -> RGBA {
        sample(NSBitmapImageRep(cgImage: image), xFraction: xFraction, yFraction: yFraction)
    }

    private func rgba(_ color: NSColor) -> RGBA {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            Issue.record("color has no sRGB representation")
            return RGBA(0, 0, 0)
        }
        return RGBA(
            Double(srgb.redComponent),
            Double(srgb.greenComponent),
            Double(srgb.blueComponent),
            Double(srgb.alphaComponent)
        )
    }

    private func expectClose(_ actual: RGBA, _ expected: RGBA, _ comment: Comment) {
        let tolerance = 0.01
        #expect(abs(actual.r - expected.r) < tolerance, comment)
        #expect(abs(actual.g - expected.g) < tolerance, comment)
        #expect(abs(actual.b - expected.b) < tolerance, comment)
    }

    @Test("the accent fills the icon background and the bars sit on top")
    func accentReachesThePixels() throws {
        let background = RGBA(0.20, 0.49, 0.96)
        let foreground = RGBA(0.99, 0.95, 0.90)
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 256,
            background: background.nsColor,
            foreground: foreground.nsColor
        ))

        // The bars span the middle 56% horizontally, so 15% in is background at mid-height.
        expectClose(pixel(image, xFraction: 0.15, yFraction: 0.5), background, "background")
        expectClose(pixel(image, xFraction: 0.5, yFraction: 0.5), foreground, "center bar")
    }

    @Test("the artwork sits on Apple's 100/1024 icon grid at every size", arguments: [1024, 128])
    func artworkIsInsetFromTheCanvas(pixels: Int) throws {
        let image = try #require(AppIconArtwork.cgImage(
            pixels: pixels,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground
        ))
        let rep = NSBitmapImageRep(cgImage: image)
        let expected = Int((Double(pixels) * 100 / 1024).rounded())
        // The rounded square's extremes sit on the mid lines, clear of the corner radius.
        let mid = pixels / 2

        let column = try #require(firstOpaqueColumn(rep, row: mid))
        let row = try #require(firstOpaqueRow(rep, column: mid))
        #expect(abs(column - expected) <= 1, "left inset at \(pixels)px")
        #expect(abs(row - expected) <= 1, "top inset at \(pixels)px")

        for (x, y) in [(0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)] {
            #expect(alpha(rep, x: x, y: y) == 0, "corner \(x),\(y) at \(pixels)px")
        }
        expectClose(pixel(image, xFraction: 0.5, yFraction: 0.5), RGBA(0.99, 0.95, 0.90), "center bar")
    }

    private func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Double {
        Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
    }

    private func firstOpaqueColumn(_ rep: NSBitmapImageRep, row: Int) -> Int? {
        (0..<rep.pixelsWide).first { alpha(rep, x: $0, y: row) > 0.5 }
    }

    private func firstOpaqueRow(_ rep: NSBitmapImageRep, column: Int) -> Int? {
        (0..<rep.pixelsHigh).first { alpha(rep, x: column, y: $0) > 0.5 }
    }

    @Test("the brand icon on disk stays sage")
    func brandColorsUnchanged() {
        expectClose(rgba(AppIconArtwork.brandBackground), RGBA(0.42, 0.54, 0.42), "sage background")
        expectClose(rgba(AppIconArtwork.brandForeground), RGBA(0.99, 0.95, 0.90), "cream foreground")
        #expect(AppIconArtwork.sizes.count == 10)
        #expect(AppIconArtwork.sizes.contains { $0.pixels == 1024 })
    }
}
