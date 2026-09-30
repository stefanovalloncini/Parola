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

    private func barX(_ index: Int, mark: AppIconArtwork.Mark = .pennino) -> Double {
        let layout = AppIconArtwork.Layout(side: 824, mark: mark)
        return Double((512 + layout.centerOffset(of: index)) / 1024)
    }

    private func expectClose(_ actual: RGBA, _ expected: RGBA, _ comment: Comment, tolerance: Double = 0.01) {
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

    @Test("the nib keeps its gold on the default accent and takes the bars' color where gold would vanish")
    @MainActor
    func nibFallsBackToTheBars() {
        #expect(DockIcon.colors(accent: variants(ThemePreset.defaultPreset.accent).light).nib == DockIcon.gold)
        #expect(DockIcon.colors(accent: variants(ThemePreset.yellow.accent).light).nib == DockIcon.ink)
        #expect(DockIcon.colors(accent: variants(ThemePreset.terracotta.accent).dark).nib == DockIcon.cream)
        for preset in ThemePreset.allCases {
            let (light, dark) = variants(preset.accent)
            for accent in [light, dark] {
                let colors = DockIcon.colors(accent: accent)
                if colors.nib == DockIcon.gold {
                    #expect(DockIcon.gold.contrast(against: accent) >= DockIcon.nibContrastMinimum,
                            "\(preset.rawValue) \(accent.hex)")
                } else {
                    #expect(colors.nib == colors.foreground, "\(preset.rawValue) \(accent.hex)")
                }
            }
        }
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

    /// Only the presets the caller is distinguishing: across all eleven, indigo sits inside blue's drift allowance.
    private func nearestPreset(to sampled: RGBA, among presets: [ThemePreset]) -> ThemePreset? {
        presets.min { lhs, rhs in
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

        let sampled: [ThemePreset] = [.blue, .yellow, .pink]
        let among = sampled.map(\.rawValue).joined(separator: ", ")
        var backgrounds: [ThemePreset: RGBA] = [:]
        for preset in sampled {
            DS.theme = preset.palette
            DockIcon.refresh()
            let icon = try #require(app.applicationIconImage, "no icon assigned for \(preset.rawValue)")
            let background = pixel(icon, xFraction: 0.15, yFraction: 0.5)
            backgrounds[preset] = background
            #expect(nearestPreset(to: background, among: sampled) == preset,
                    "\(preset.rawValue) icon sampled \(background.hex); of \(among) the nearest is \(nearestPreset(to: background, among: sampled)?.rawValue ?? "none")")

            let bar = pixel(icon, xFraction: barX(2), yFraction: 0.5)
            let expectedBar = preset == .yellow ? DockIcon.ink : DockIcon.cream
            let otherBar = preset == .yellow ? DockIcon.cream : DockIcon.ink
            #expect(distance(bar, expectedBar) < distance(bar, otherBar),
                    "\(preset.rawValue) bars sampled \(bar.hex)")

            let nib = pixel(icon, xFraction: 0.5, yFraction: 0.3)
            let expectedNib = preset == .yellow ? DockIcon.ink : DockIcon.gold
            let otherNib = preset == .yellow ? DockIcon.gold : DockIcon.cream
            #expect(distance(nib, expectedNib) < distance(nib, otherNib),
                    "\(preset.rawValue) nib sampled \(nib.hex)")
        }

        // A stuck icon would sample identically for every accent.
        #expect(distance(backgrounds[.blue]!, backgrounds[.yellow]!) > 0.2)
        #expect(distance(backgrounds[.blue]!, backgrounds[.pink]!) > 0.2)
    }

    @Test("the rendered icon carries a ladder of representations up to what the Dock draws")
    @MainActor
    func imageHasRepresentations() {
        let image = DockIcon.image(DockIcon.colors(accent: RGBA(0.20, 0.49, 0.96)))
        let sizes = Set(image.representations.map(\.pixelsWide)).sorted()
        #expect(sizes == [16, 32, 64, 128, 256, 512])
        #expect(image.size.width == 512)
    }
}
