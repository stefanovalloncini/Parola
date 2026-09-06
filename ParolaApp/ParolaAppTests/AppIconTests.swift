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

    /// The `applicationIconImage` getter hands back an image whose representations aren't
    /// `NSBitmapImageRep`, so sampling has to go through a rasterization rather than the reps.
    private func pixel(_ image: NSImage, xFraction: Double, yFraction: Double) -> RGBA {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("icon could not be rasterized")
            return RGBA(0, 0, 0)
        }
        return sample(NSBitmapImageRep(cgImage: cgImage), xFraction: xFraction, yFraction: yFraction)
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

    @Test("the artwork sits on the macOS icon grid, inset from the canvas edge")
    func artworkIsInsetFromTheCanvas() throws {
        let image = try #require(AppIconArtwork.cgImage(
            pixels: 256,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground
        ))

        #expect(pixel(image, xFraction: 0.05, yFraction: 0.5).a == 0)
        #expect(pixel(image, xFraction: 0.05, yFraction: 0.05).a == 0)
        expectClose(pixel(image, xFraction: 0.12, yFraction: 0.5), RGBA(0.42, 0.54, 0.42), "background")
        expectClose(pixel(image, xFraction: 0.5, yFraction: 0.5), RGBA(0.99, 0.95, 0.90), "center bar")
    }

    @Test("the brand icon on disk stays sage")
    func brandColorsUnchanged() {
        expectClose(rgba(AppIconArtwork.brandBackground), RGBA(0.42, 0.54, 0.42), "sage background")
        expectClose(rgba(AppIconArtwork.brandForeground), RGBA(0.99, 0.95, 0.90), "cream foreground")
        #expect(AppIconArtwork.sizes.count == 10)
        #expect(AppIconArtwork.sizes.contains { $0.pixels == 1024 })
    }

    private func distance(_ a: RGBA, _ b: RGBA) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    private func nearestPreset(to sampled: RGBA) -> ThemePreset? {
        ThemePreset.allCases.min { lhs, rhs in
            distance(sampled, variants(lhs.accent).light) < distance(sampled, variants(rhs.accent).light)
        }
    }

    /// End-to-end through the real assignment. `applicationIconImage` round-trips through AppKit's
    /// own color handling, which shifts components by up to ~0.15 — so this classifies the sampled
    /// color against the preset palette rather than asserting exact sRGB.
    @Test("refreshing hands the running application an icon tinted to the current accent")
    @MainActor
    func refreshAssignsTintedIcon() throws {
        let app = try #require(NSApp, "this suite needs the app test host")
        let previousTheme = DS.theme
        defer {
            DS.theme = previousTheme
            DockIcon.refresh()
        }

        var backgrounds: [ThemePreset: RGBA] = [:]
        for preset in [ThemePreset.blue, .yellow, .pink] {
            DS.theme = preset.palette
            DockIcon.refresh()
            let icon = try #require(app.applicationIconImage, "no icon assigned for \(preset.rawValue)")
            let background = pixel(icon, xFraction: 0.15, yFraction: 0.5)
            backgrounds[preset] = background
            #expect(nearestPreset(to: background) == preset,
                    "\(preset.rawValue) icon sampled \(background.hex), nearest \(nearestPreset(to: background)?.rawValue ?? "none")")

            let bar = pixel(icon, xFraction: 0.5, yFraction: 0.5)
            let expectedBar = preset == .yellow ? DockIcon.ink : DockIcon.cream
            let otherBar = preset == .yellow ? DockIcon.cream : DockIcon.ink
            #expect(distance(bar, expectedBar) < distance(bar, otherBar),
                    "\(preset.rawValue) bars sampled \(bar.hex)")
        }

        // A stuck icon would sample identically for every accent.
        #expect(distance(backgrounds[.blue]!, backgrounds[.yellow]!) > 0.2)
        #expect(distance(backgrounds[.blue]!, backgrounds[.pink]!) > 0.2)
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
