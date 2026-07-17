import Foundation
import Testing
@testable import Parola

@Suite("Focused field locator")
struct FocusedFieldLocatorTests {
    private let primary: (frame: NSRect, visible: NSRect) = (
        NSRect(x: 0, y: 0, width: 1512, height: 982),
        NSRect(x: 0, y: 0, width: 1512, height: 944)
    )
    private let secondary: (frame: NSRect, visible: NSRect) = (
        NSRect(x: 1512, y: 0, width: 1920, height: 1080),
        NSRect(x: 1512, y: 0, width: 1920, height: 1055)
    )

    @Test("AX top-left rects flip into AppKit coordinates")
    func coordinateFlip() {
        let flipped = FocusedFieldLocator.appKitRect(
            fromTopLeft: CGRect(x: 100, y: 100, width: 200, height: 24),
            primaryScreenHeight: 982
        )
        #expect(flipped == NSRect(x: 100, y: 982 - 100 - 24, width: 200, height: 24))
    }

    @Test("caret wins over the element frame")
    func caretPreferred() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: CGRect(x: 400, y: 300, width: 2, height: 18),
            elementTopLeft: CGRect(x: 380, y: 280, width: 400, height: 120),
            primaryScreenHeight: 982,
            screens: [primary]
        )
        #expect(anchor?.source == .caret)
        #expect(anchor?.rect == NSRect(x: 400, y: 982 - 300 - 18, width: 2, height: 18))
        #expect(anchor?.screenVisibleFrame == primary.visible)
    }

    @Test("element frame anchors when there is no caret")
    func elementFallback() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: nil,
            elementTopLeft: CGRect(x: 380, y: 280, width: 400, height: 120),
            primaryScreenHeight: 982,
            screens: [primary]
        )
        #expect(anchor?.source == .field)
    }

    @Test("giant elements are not fields")
    func giantElementRejected() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: nil,
            elementTopLeft: CGRect(x: 0, y: 0, width: 1500, height: 900),
            primaryScreenHeight: 982,
            screens: [primary]
        )
        #expect(anchor == nil)
    }

    @Test("anchor on the second display carries that screen's frames")
    func secondDisplay() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: CGRect(x: 2000, y: 300, width: 2, height: 18),
            elementTopLeft: nil,
            primaryScreenHeight: 982,
            screens: [primary, secondary]
        )
        #expect(anchor?.screenVisibleFrame == secondary.visible)
    }

    @Test("no screens means no anchor")
    func noScreens() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: CGRect(x: 10, y: 10, width: 2, height: 18),
            elementTopLeft: nil,
            primaryScreenHeight: 982,
            screens: []
        )
        #expect(anchor == nil)
    }

    @Test("zero element frames are not anchors")
    func zeroElementRejected() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: nil,
            elementTopLeft: .zero,
            primaryScreenHeight: 900,
            screens: [primary]
        )
        #expect(anchor == nil)
    }

    @Test("a degenerate caret falls through to the element frame")
    func degenerateCaretFallsThrough() {
        let anchor = FocusedFieldLocator.anchor(
            caretTopLeft: CGRect(x: CGFloat.nan, y: 10, width: 2, height: 18),
            elementTopLeft: CGRect(x: 380, y: 280, width: 400, height: 120),
            primaryScreenHeight: 982,
            screens: [primary]
        )
        #expect(anchor?.source == .field)
    }
}
