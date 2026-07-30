import AppKit
import Foundation
import Testing
@testable import Parola

@Suite("App icon")
struct AppIconTests {

    private func variants(_ color: ThemeColor) -> (light: RGBA, dark: RGBA) {
        guard case .dynamic(let light, let dark) = color else {
            Issue.record("preset accents are expected to be dynamic, got a system color")
            return (RGBA(0, 0, 0), RGBA(0, 0, 0))
        }
        return (light, dark)
    }

    private func pixel(_ image: CGImage, xFraction: Double, yFraction: Double) -> RGBA {
        let rep = NSBitmapImageRep(cgImage: image)
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

    @Test("Amber is the one preset light enough to need dark bars")
    @MainActor
    func amberFlipsTheBars() {
        for preset in ThemePreset.allCases {
            let (light, dark) = variants(preset.accent)
            let expected = preset == .yellow ? DockIcon.ink : DockIcon.cream
            #expect(DockIcon.colors(accent: light).foreground == expected,
                    "\(preset.rawValue) light variant")
            if preset != .yellow {
                #expect(DockIcon.colors(accent: dark).foreground == DockIcon.cream,
                        "\(preset.rawValue) dark variant")
            }
        }
    }

    @Test("bars flip at the shared luminance threshold")
    @MainActor
    func flipsAtThreshold() {
        #expect(DockIcon.colors(accent: RGBA(1, 1, 1)).foreground == DockIcon.ink)
        #expect(DockIcon.colors(accent: RGBA(0, 0, 0)).foreground == DockIcon.cream)
        #expect(RGBA(1, 1, 1).relativeLuminance > RGBA.darkForegroundLuminance)
        #expect(RGBA(0, 0, 0).relativeLuminance < RGBA.darkForegroundLuminance)
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

    @Test("the brand icon on disk stays sage")
    func brandColorsUnchanged() {
        expectClose(rgba(AppIconArtwork.brandBackground), RGBA(0.42, 0.54, 0.42), "sage background")
        expectClose(rgba(AppIconArtwork.brandForeground), RGBA(0.99, 0.95, 0.90), "cream foreground")
        #expect(AppIconArtwork.sizes.count == 10)
        #expect(AppIconArtwork.sizes.contains { $0.pixels == 1024 })
    }

    @Test("the rendered icon carries a full ladder of representations")
    @MainActor
    func imageHasRepresentations() {
        let image = DockIcon.image(DockIcon.colors(accent: RGBA(0.20, 0.49, 0.96)))
        let sizes = Set(image.representations.map(\.pixelsWide)).sorted()
        #expect(sizes == [16, 32, 64, 128, 256, 512, 1024])
        #expect(image.size.width == 1024)
    }
}
