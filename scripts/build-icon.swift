#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Generates the macOS AppIcon set for Parola.
// Run from the repo root: `swift scripts/build-icon.swift [--force]`
//
// The PNGs are committed. Without --force, the script refuses to overwrite
// them — a stray run would otherwise silently change the brand icon.

let args = CommandLine.arguments
let force = args.contains("--force") || args.contains("-f")

if args.contains("--help") || args.contains("-h") {
    print("""
    Usage: swift scripts/build-icon.swift [--force]

      --force, -f   Overwrite committed AppIcon.appiconset PNGs.

    The generated icons are committed to the repo. Run this only when changing
    the brand icon, and commit the regenerated files together with whatever
    drove the change.
    """)
    exit(0)
}

let outDir = URL(fileURLWithPath: "ParolaApp/ParolaApp/Resources/Assets.xcassets/AppIcon.appiconset")

let existingPNGs = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }) ?? []
if !existingPNGs.isEmpty && !force {
    print("✘ \(outDir.path) already has \(existingPNGs.count) committed PNGs.")
    print("  Re-run with --force to overwrite them.")
    exit(1)
}

let sizes: [(name: String, pixels: Int)] = [
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

let backgroundColor = NSColor(srgbRed: 0.42, green: 0.54, blue: 0.42, alpha: 1)
let foregroundColor = NSColor(srgbRed: 0.99, green: 0.95, blue: 0.90, alpha: 1)

func drawIcon(into context: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.saveGState()

    // Background with macOS-style continuous corner radius (~22% of side).
    let cornerRadius = size * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.setFillColor(backgroundColor.cgColor)
    context.fillPath()

    // Bars representing a waveform. Heights chosen to look symmetric and intentional.
    let bars: [CGFloat] = [0.32, 0.62, 0.84, 0.50, 0.92, 0.50, 0.84, 0.62, 0.32]
    let barCount = CGFloat(bars.count)
    let usableWidth = size * 0.56
    let usableHeight = size * 0.72
    let spacing = usableWidth / (barCount * 2)
    let barWidth = (usableWidth - spacing * (barCount - 1)) / barCount
    let originX = (size - usableWidth) / 2
    let centerY = size / 2

    context.setFillColor(foregroundColor.cgColor)
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

func writePNG(at url: URL, pixels: Int) throws {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "build-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create context"])
    }
    drawIcon(into: context, size: size)
    guard let image = context.makeImage() else {
        throw NSError(domain: "build-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not make image"])
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "build-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try data.write(to: url, options: .atomic)
}

let manifest: [String: Any] = [
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

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for entry in sizes {
    try writePNG(at: outDir.appendingPathComponent(entry.name), pixels: entry.pixels)
    print("wrote \(entry.name) (\(entry.pixels)px)")
}

let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
