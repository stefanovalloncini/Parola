import AppKit
import ApplicationServices

struct ScreenGeometry: Sendable {
    var primaryHeight: CGFloat
    var screens: [(frame: NSRect, visible: NSRect)]

    @MainActor
    static func current() -> ScreenGeometry {
        ScreenGeometry(
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0,
            screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        )
    }
}

/// Blocks on accessibility calls; callers run it off the main actor.
protocol FieldAnchorProviding: Sendable {
    func currentAnchor(on geometry: ScreenGeometry) -> FieldAnchor?
}

struct FocusedFieldLocator: FieldAnchorProviding {
    func currentAnchor(on geometry: ScreenGeometry) -> FieldAnchor? {
        guard AXIsProcessTrusted() else { return nil }
        guard let element = Self.focusedElement() else { return nil }
        return Self.anchor(
            caretTopLeft: Self.caretRect(of: element),
            elementTopLeft: Self.elementFrame(of: element),
            primaryScreenHeight: geometry.primaryHeight,
            screens: geometry.screens
        )
    }

    nonisolated static func appKitRect(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    nonisolated static func anchor(
        caretTopLeft: CGRect?,
        elementTopLeft: CGRect?,
        primaryScreenHeight: CGFloat,
        screens: [(frame: NSRect, visible: NSRect)]
    ) -> FieldAnchor? {
        if let caret = caretTopLeft, isUsable(caret) {
            let rect = appKitRect(fromTopLeft: caret, primaryScreenHeight: primaryScreenHeight)
            if let screen = screen(containing: rect, in: screens) {
                return FieldAnchor(rect: rect, source: .caret, screenFrame: screen.frame, screenVisibleFrame: screen.visible)
            }
        }
        if let element = elementTopLeft, isUsable(element) {
            let rect = appKitRect(fromTopLeft: element, primaryScreenHeight: primaryScreenHeight)
            guard let screen = screen(containing: rect, in: screens) else { return nil }
            let screenArea = screen.frame.width * screen.frame.height
            guard screenArea > 0, rect.width * rect.height <= screenArea * 0.5 else { return nil }
            return FieldAnchor(rect: rect, source: .field, screenFrame: screen.frame, screenVisibleFrame: screen.visible)
        }
        return nil
    }

    nonisolated private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect != .zero
    }

    nonisolated static func screen(
        containing rect: NSRect,
        in screens: [(frame: NSRect, visible: NSRect)]
    ) -> (frame: NSRect, visible: NSRect)? {
        let mid = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = screens.first(where: { $0.frame.contains(mid) }) { return hit }
        let best = screens.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        }
        guard let best, intersectionArea(best.frame, rect) > 0 else { return nil }
        return best
    }

    nonisolated private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    /// The default AX messaging timeout is 6 s per call; a beachballing frontmost app would hold the probe queue that long.
    private static let messagingTimeout: Float = 0.25

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        )
        guard result == .success, let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect) else { return nil }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect != .zero else { return nil }
        return rect
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((positionValue as! AXValue), .cgPoint, &origin),
              AXValueGetValue((sizeValue as! AXValue), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
