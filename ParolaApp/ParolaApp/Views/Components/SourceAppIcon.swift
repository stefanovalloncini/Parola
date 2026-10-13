import AppKit
import SwiftUI

/// Where a source app's bundle ID meets the machine it is installed on.
enum SourceAppIcon {
    static func appURL(forBundleID id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// The first of `ids` that is installed, in sorted order so two installs of one vendor resolve the same way every time.
    static func installedBundleID(among ids: Set<String>) -> String? {
        ids.sorted().first { appURL(forBundleID: $0) != nil }
    }

    static func workspaceIcon(forBundleID id: String) -> NSImage? {
        appURL(forBundleID: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// App icons carry transparent padding and a shadow inside their bounds; cropping to the solid part lets the icon fill a tile's frame like a kind tile does.
    static func croppedToOpaqueBounds(_ image: NSImage, pixels: Int = 128, minimumAlpha: UInt8 = 128) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return image }
        var minX = pixels, minY = pixels, maxX = -1, maxY = -1
        for y in 0..<pixels {
            let row = data + y * rep.bytesPerRow
            for x in 0..<pixels where row[x * 4 + 3] >= minimumAlpha {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, let cg = rep.cgImage,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

/// App icons by bundle ID. A row asks for one while it draws, so the first ask only schedules the lookup and every later one reads the result.
@Observable
@MainActor
final class SourceAppIconCache {
    static let shared = SourceAppIconCache()

    private enum Lookup {
        case icon(NSImage)
        case missing
    }

    private var lookups: [String: Lookup] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let resolve: @MainActor (String) -> NSImage?
    @ObservationIgnored private(set) var resolveCount = 0

    init(resolve: @escaping @MainActor (String) -> NSImage? = { SourceAppIcon.workspaceIcon(forBundleID: $0) }) {
        self.resolve = resolve
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if case .icon(let image) = lookups[bundleID] { return image }
        if lookups[bundleID] == nil, requested.insert(bundleID).inserted {
            Task { @MainActor [weak self] in self?.finishLookup(of: bundleID) }
        }
        return nil
    }

    private func finishLookup(of bundleID: String) {
        resolveCount += 1
        lookups[bundleID] = resolve(bundleID).map { .icon(SourceAppIcon.croppedToOpaqueBounds($0)) } ?? .missing
    }
}

private struct SourceAppIconsKey: EnvironmentKey {
    static let defaultValue: SourceAppIconCache? = nil
}

extension EnvironmentValues {
    var sourceAppIcons: SourceAppIconCache? {
        get { self[SourceAppIconsKey.self] }
        set { self[SourceAppIconsKey.self] = newValue }
    }
}
