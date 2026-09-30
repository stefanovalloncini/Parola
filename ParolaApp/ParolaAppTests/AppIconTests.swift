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

    private func barX(_ index: Int, mark: AppIconArtwork.Mark = .pennino) -> Double {
        let layout = AppIconArtwork.Layout(side: 824, mark: mark)
        return Double((512 + layout.centerOffset(of: index)) / 1024)
    }

    private func expectClose(_ actual: RGBA, _ expected: RGBA, _ comment: Comment, tolerance: Double = 0.01) {
        #expect(abs(actual.r - expected.r) < tolerance, comment)
        #expect(abs(actual.g - expected.g) < tolerance, comment)
        #expect(abs(actual.b - expected.b) < tolerance, comment)
    }

    @Test("the artwork paints its background and bars in the colours it's given")
    func artworkPaintsTheGivenColours() throws {
        let background = RGBA(0.20, 0.49, 0.96)
        let foreground = RGBA(0.99, 0.95, 0.90)
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 256,
            background: background.nsColor,
            foreground: foreground.nsColor
        ))

        // The bars span the middle 56% horizontally, so 15% in is background at mid-height.
        expectClose(pixel(image, xFraction: 0.15, yFraction: 0.5), background, "background", tolerance: 0.06)
        expectClose(pixel(image, xFraction: barX(2), yFraction: 0.5), foreground, "bar")
    }

    @Test("the background is lit from the top")
    func backgroundIsLitFromTheTop() throws {
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 256,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground
        ))
        let top = pixel(image, xFraction: 0.5, yFraction: 0.15)
        let bottom = pixel(image, xFraction: 0.5, yFraction: 0.85)
        #expect(top.relativeLuminance > bottom.relativeLuminance)
    }

    @Test("the nib is drawn in its own color and cut through by its slit")
    func nibIsCutThrough() throws {
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 1024,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground,
            nib: AppIconArtwork.brandNib
        ))
        let gold = rgba(AppIconArtwork.brandNib)
        expectClose(pixel(image, xFraction: 0.5, yFraction: 0.3), gold, "nib body")
        #expect(distance(pixel(image, xFraction: 0.5, yFraction: 0.5), gold) > 0.3, "slit")
    }

    @Test("the classic waveform keeps its nine bars and its width")
    func classicWaveformKeepsItsCenterBar() throws {
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 256,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground,
            mark: .waveform
        ))
        expectClose(pixel(image, xFraction: 0.5, yFraction: 0.5), rgba(AppIconArtwork.brandForeground), "center bar")
        #expect(abs(AppIconArtwork.Layout(side: 824, mark: .waveform).width - 824 * 0.56) < 0.001)
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
        expectClose(pixel(image, xFraction: barX(2), yFraction: 0.5), RGBA(0.99, 0.95, 0.90), "bar")
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
        expectClose(rgba(AppIconArtwork.brandNib), RGBA(0.91, 0.72, 0.38), "gold nib")
        #expect(AppIconArtwork.sizes.count == 10)
        #expect(AppIconArtwork.sizes.contains { $0.pixels == 1024 })
    }

    private func distance(_ a: RGBA, _ b: RGBA) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }
}
