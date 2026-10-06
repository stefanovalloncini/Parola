import AppKit

struct FieldAnchor: Equatable {
    enum Source: Equatable {
        case caret
        case field
    }

    var rect: NSRect
    var source: Source
    var screenFrame: NSRect
    var screenVisibleFrame: NSRect
}

enum DictationHUDPlacement {
    struct Context {
        var style: DictationIndicatorStyle
        var hasPartial: Bool
        var failedMessageVisible: Bool
        var listeningCompact: Bool
        var anchor: FieldAnchor?
        var screenFrame: NSRect
        var screenVisibleFrame: NSRect
    }

    static func frame(_ context: Context) -> NSRect {
        let size = size(for: context)
        guard context.screenFrame != .zero else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = context.screenVisibleFrame
        let origin: NSPoint
        switch context.style {
        case .nearField:
            guard let anchor = context.anchor else {
                origin = overlayOrigin(for: size, in: visible)
                break
            }
            let anchorVisible = anchor.screenVisibleFrame
            var y = anchor.rect.minY - 8 - size.height
            if y < anchorVisible.minY {
                y = anchor.rect.maxY + 8
            }
            y = min(y, anchorVisible.maxY - size.height - 8)
            let x = min(max(anchor.rect.minX, anchorVisible.minX + 8), anchorVisible.maxX - size.width - 8)
            origin = NSPoint(x: x, y: y)
        case .overlay:
            origin = overlayOrigin(for: size, in: visible)
        case .notch:
            let topY = context.screenFrame.maxY - visible.maxY > 30
                ? context.screenFrame.maxY - size.height - 4
                : visible.maxY - size.height - 8
            origin = NSPoint(x: visible.midX - size.width / 2, y: topY)
        case .minimal:
            origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Bottom centre of the visible screen, 100 pt up: the overlay's spot.
    static func overlayOrigin(for size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 100)
    }

    /// The overlay's height with words in it, the most it grows to.
    static let overlayTallestHeight: CGFloat = 156

    /// The recording pill's spot until it is dragged: centred over the overlay at its tallest, so a dictation during a take never covers the pill's Stop.
    static func aboveOverlayOrigin(for size: NSSize, in visible: NSRect) -> NSPoint {
        let overlay = overlayOrigin(for: size, in: visible)
        return NSPoint(x: overlay.x, y: overlay.y + overlayTallestHeight + 12)
    }

    private static func size(for context: Context) -> NSSize {
        switch context.style {
        case .nearField:
            let expanded = context.hasPartial || context.failedMessageVisible
            return NSSize(width: expanded ? 360 : 200, height: expanded ? 96 : 44)
        case .overlay:
            if context.failedMessageVisible { return NSSize(width: 380, height: 84) }
            let compactWidth: CGFloat = context.listeningCompact ? 336 : 268
            return NSSize(width: context.hasPartial ? 380 : compactWidth, height: context.hasPartial ? overlayTallestHeight : 64)
        case .notch:
            if context.failedMessageVisible { return NSSize(width: 372, height: 52) }
            return NSSize(width: context.hasPartial ? 372 : 252, height: 36)
        case .minimal:
            // A failure borrows the near-field card: a lone dot can't say why.
            if context.failedMessageVisible { return NSSize(width: 360, height: 96) }
            return NSSize(width: 44, height: 44)
        }
    }
}
