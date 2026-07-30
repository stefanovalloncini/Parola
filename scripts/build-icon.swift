import AppKit
import CoreGraphics
import Foundation

// Generates the macOS AppIcon set for Parola. Run from the repo root: `scripts/build-icon.sh [--force]`.
//
// The PNGs are committed. Without --force, the script refuses to overwrite them — a stray run
// would otherwise silently change the brand icon.
//
// The drawing lives in ParolaApp/ParolaApp/AppIconArtwork.swift, which build-icon.sh compiles
// alongside this file. The running app tints that same artwork to the theme accent; the icon on
// disk stays the sage brand color.

@main
struct BuildIcon {
    static let outDir = URL(fileURLWithPath: "ParolaApp/ParolaApp/Resources/Assets.xcassets/AppIcon.appiconset")

    static func main() throws {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            Usage: scripts/build-icon.sh [--force]

              --force, -f   Overwrite committed AppIcon.appiconset PNGs.

            The generated icons are committed to the repo. Run this only when changing
            the brand icon, and commit the regenerated files together with whatever
            drove the change.
            """)
            exit(0)
        }

        let force = args.contains("--force") || args.contains("-f")
        let existingPNGs = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }) ?? []
        if !existingPNGs.isEmpty && !force {
            print("✘ \(outDir.path) already has \(existingPNGs.count) committed PNGs.")
            print("  Re-run with --force to overwrite them.")
            exit(1)
        }

        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for entry in AppIconArtwork.sizes {
            try writePNG(at: outDir.appendingPathComponent(entry.name), pixels: entry.pixels)
            print("wrote \(entry.name) (\(entry.pixels)px)")
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("Contents.json"))
        print("wrote Contents.json")
    }

    static func writePNG(at url: URL, pixels: Int) throws {
        guard let image = AppIconArtwork.cgImage(
            pixels: pixels,
            background: AppIconArtwork.brandBackground,
            foreground: AppIconArtwork.brandForeground
        ) else {
            throw NSError(domain: "build-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(pixels)px"])
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "build-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
        }
        try data.write(to: url, options: .atomic)
    }

    static let manifest: [String: Any] = [
        "info": ["author": "xcode", "version": 1],
        "images": [
            ["idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16x16.png"],
            ["idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_16x16@2x.png"],
            ["idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32x32.png"],
            ["idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_32x32@2x.png"],
            ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"],
            ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"],
            ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"],
            ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"],
            ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"],
            ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"],
        ],
    ]
}
