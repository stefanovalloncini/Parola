import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("Source app icons")
struct SourceAppIconCacheTests {
    private func image() -> NSImage { NSImage(size: NSSize(width: 4, height: 4)) }

    private func paddedSquare(side: CGFloat, margin: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.red.setFill()
            NSRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin).fill()
            return true
        }
    }

    @Test("a padded icon is cropped to its opaque square, with no margin left")
    func cropsTransparentMargin() throws {
        let cropped = SourceAppIcon.croppedToOpaqueBounds(paddedSquare(side: 100, margin: 20))

        #expect(cropped.size.width == cropped.size.height)
        #expect(abs(cropped.size.width - 128 * 0.6) <= 2)
        let cg = try #require(cropped.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        for point in [(0, 0), (cg.width - 1, 0), (0, cg.height - 1), (cg.width - 1, cg.height - 1)] {
            let alpha = rep.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 0
            #expect(alpha > 0.9, "corner \(point) is solid")
        }
    }

    @Test("a wide opaque shape keeps its aspect")
    func keepsAspect() {
        let wide = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
            NSColor.blue.setFill()
            NSRect(x: 10, y: 30, width: 80, height: 40).fill()
            return true
        }
        let cropped = SourceAppIcon.croppedToOpaqueBounds(wide)
        #expect(abs(cropped.size.width / cropped.size.height - 2) < 0.1)
    }

    @Test("the cache serves the cropped icon")
    func cacheCrops() async {
        let cache = SourceAppIconCache { _ in paddedSquare(side: 100, margin: 20) }
        _ = cache.icon(for: "x")
        await waitUntil { cache.icon(for: "x") != nil }
        #expect(cache.icon(for: "x").map { abs($0.size.width - 128 * 0.6) <= 2 } == true)
    }

    @Test("an icon resolves once, off the call that asked, and is served from the cache after")
    func resolvesOnceAndCaches() async {
        var asked: [String] = []
        let icon = image()
        let cache = SourceAppIconCache { id in
            asked.append(id)
            return icon
        }

        #expect(cache.icon(for: "us.zoom.xos") == nil)
        #expect(asked.isEmpty, "the first ask only schedules the lookup")
        await waitUntil { cache.icon(for: "us.zoom.xos") != nil }
        for _ in 0..<50 { #expect(cache.icon(for: "us.zoom.xos") === icon) }

        #expect(asked == ["us.zoom.xos"])
    }

    @Test("an app that cannot be found is looked up once and has no icon")
    func missingIsRemembered() async {
        let cache = SourceAppIconCache { _ in nil }

        #expect(cache.icon(for: "com.example.gone") == nil)
        await waitUntil { cache.resolveCount == 1 }
        for _ in 0..<10 { #expect(cache.icon(for: "com.example.gone") == nil) }
        await settle()

        #expect(cache.resolveCount == 1)
    }

    @Test("no bundle ID asks for nothing")
    func nilAsksNothing() async {
        let cache = SourceAppIconCache { _ in nil }
        #expect(cache.icon(for: nil) == nil)
        await settle()
        #expect(cache.resolveCount == 0)
    }

    @Test("the tile shows the app's icon when it has one, and its kind tile before and without")
    func tileFace() async {
        let icon = image()
        let cache = SourceAppIconCache { $0 == "us.zoom.xos" ? icon : nil }

        func isKind(_ face: EntryTile.Face) -> Bool {
            if case .kind = face { return true }
            return false
        }
        #expect(isKind(EntryTile.face(sourceAppBundleID: "us.zoom.xos", in: cache)), "before the lookup lands")
        await waitUntil { cache.icon(for: "us.zoom.xos") != nil }

        guard case .appIcon(let shown) = EntryTile.face(sourceAppBundleID: "us.zoom.xos", in: cache) else {
            Issue.record("expected the app icon")
            return
        }
        #expect(shown === icon)
        #expect(isKind(EntryTile.face(sourceAppBundleID: nil, in: cache)))
        _ = cache.icon(for: "com.example.gone")
        await settle()
        #expect(isKind(EntryTile.face(sourceAppBundleID: "com.example.gone", in: cache)))
    }
}
