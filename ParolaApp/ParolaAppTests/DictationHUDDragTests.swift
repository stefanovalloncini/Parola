import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Dictation HUD drag", .serialized)
struct DictationHUDDragTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)

    private func context(_ style: DictationIndicatorStyle, hasPartial: Bool = false, failed: Bool = false) -> DictationHUDPlacement.Context {
        DictationHUDPlacement.Context(
            style: style,
            hasPartial: hasPartial,
            failedMessageVisible: failed,
            listeningCompact: true,
            anchor: nil,
            screenFrame: screen,
            screenVisibleFrame: visible
        )
    }

    private func positioner(_ defaults: UserDefaults = temporaryDefaults()) -> DictationHUDPositioner {
        let screen = self.screen
        return DictationHUDPositioner(defaults: defaults, screens: { [screen] })
    }

    /// Never ordered in: a move still posts didMove, and nothing reaches the screen.
    private func makePanel() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test("a dragged overlay keeps its bottom centre when it grows for words")
    func overlayKeepsTheDrag() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.overlay))
        #expect(panel.frame == DictationHUDPlacement.frame(context(.overlay)))

        panel.setFrameOrigin(NSPoint(x: 200, y: 600))
        let dragged = panel.frame
        hud.place(panel, context(.overlay, hasPartial: true))

        #expect(panel.frame.midX == dragged.midX)
        #expect(panel.frame.minY == dragged.minY)
        #expect(panel.frame.size == DictationHUDPlacement.frame(context(.overlay, hasPartial: true)).size)
    }

    @Test("a dragged notch keeps its top centre, and a dragged dot its bottom right")
    func notchAndMinimalKeepTheirEdge() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.notch))
        panel.setFrameOrigin(NSPoint(x: 300, y: 500))
        let notch = panel.frame
        hud.place(panel, context(.notch, failed: true))
        #expect(panel.frame.midX == notch.midX)
        #expect(panel.frame.maxY == notch.maxY)

        hud.place(panel, context(.minimal))
        panel.setFrameOrigin(NSPoint(x: 700, y: 300))
        let dot = panel.frame
        hud.place(panel, context(.minimal, failed: true))
        #expect(panel.frame.maxX == dot.maxX)
        #expect(panel.frame.minY == dot.minY)
    }

    @Test("its own moves aren't taken for a drag")
    func placementIsNotADrag() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.overlay))
        hud.place(panel, context(.overlay, hasPartial: true))
        #expect(panel.frame == DictationHUDPlacement.frame(context(.overlay, hasPartial: true)))
        hud.place(panel, context(.overlay))
        #expect(panel.frame == DictationHUDPlacement.frame(context(.overlay)))
    }

    @Test("each style keeps its own spot")
    func spotsArePerStyle() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.overlay))
        panel.setFrameOrigin(NSPoint(x: 200, y: 600))
        hud.place(panel, context(.notch))
        #expect(panel.frame == DictationHUDPlacement.frame(context(.notch)))
    }

    @Test("the spot outlives the session, as the recording pill's does")
    func spotIsRemembered() {
        let defaults = temporaryDefaults()
        let panel = makePanel()
        let first = positioner(defaults)
        first.place(panel, context(.overlay))
        panel.setFrameOrigin(NSPoint(x: 200, y: 600))
        let dragged = panel.frame

        let next = makePanel()
        positioner(defaults).place(next, context(.overlay))
        #expect(next.frame == dragged)
    }

    @Test("a spot on a screen that's gone falls back to the style's place")
    func lostScreenFallsBack() {
        let defaults = temporaryDefaults()
        let panel = makePanel()
        let first = DictationHUDPositioner(defaults: defaults, screens: { [NSRect(x: 0, y: 0, width: 3000, height: 2000)] })
        first.place(panel, context(.overlay))
        panel.setFrameOrigin(NSPoint(x: 2400, y: 1500))

        let next = makePanel()
        positioner(defaults).place(next, context(.overlay))
        #expect(next.frame == DictationHUDPlacement.frame(context(.overlay)))
    }

    @Test("a HUD dragged to an edge stays on the screen as it grows")
    func growsOntoTheScreen() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.overlay))
        panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width, y: screen.maxY - panel.frame.height))
        hud.place(panel, context(.overlay, hasPartial: true))
        #expect(screen.contains(panel.frame))
    }

    @Test("the near-field HUD follows the field, so it can't be dragged; the others can")
    func nearFieldIsFixed() {
        let hud = positioner()
        let panel = makePanel()
        hud.place(panel, context(.nearField))
        #expect(panel.isMovableByWindowBackground == false)
        hud.place(panel, context(.overlay))
        #expect(panel.isMovableByWindowBackground)
    }
}
