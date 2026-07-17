import Foundation
import Testing
@testable import Parola

@Suite("Dictation HUD placement")
struct DictationHUDPlacementTests {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 944)

    private func context(
        style: DictationIndicatorStyle,
        hasPartial: Bool = false,
        failedMessageVisible: Bool = false,
        listeningCompact: Bool = false,
        anchor: FieldAnchor? = nil
    ) -> DictationHUDPlacement.Context {
        DictationHUDPlacement.Context(
            style: style,
            hasPartial: hasPartial,
            failedMessageVisible: failedMessageVisible,
            listeningCompact: listeningCompact,
            anchor: anchor,
            screenFrame: screenFrame,
            screenVisibleFrame: visibleFrame
        )
    }

    @Test("overlay compact while listening")
    func overlayListening() {
        let frame = DictationHUDPlacement.frame(context(style: .overlay, listeningCompact: true))
        #expect(frame == NSRect(x: 588, y: 100, width: 336, height: 64))
    }

    @Test("overlay compact while idle")
    func overlayIdle() {
        let frame = DictationHUDPlacement.frame(context(style: .overlay))
        #expect(frame == NSRect(x: 622, y: 100, width: 268, height: 64))
    }

    @Test("overlay grows for partial text")
    func overlayPartial() {
        let frame = DictationHUDPlacement.frame(context(style: .overlay, hasPartial: true))
        #expect(frame.size == NSSize(width: 380, height: 156))
        #expect(frame.midX == 756)
    }

    @Test("notch pins under the camera housing when the gap is deep")
    func notchDeepGap() {
        let frame = DictationHUDPlacement.frame(context(style: .notch))
        #expect(frame == NSRect(x: 630, y: 982 - 36 - 4, width: 252, height: 36))
    }

    @Test("notch falls below the menu bar on shallow gaps")
    func notchShallowGap() {
        var c = context(style: .notch)
        c.screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 960)
        let frame = DictationHUDPlacement.frame(c)
        #expect(frame == NSRect(x: 630, y: 944 - 36 - 8, width: 252, height: 36))
    }

    @Test("minimal sits in the bottom-right corner")
    func minimalCorner() {
        let frame = DictationHUDPlacement.frame(context(style: .minimal))
        #expect(frame == NSRect(x: 1512 - 44 - 24, y: 24, width: 44, height: 44))
    }

    @Test("zero screen keeps the size and zero origin")
    func zeroScreen() {
        var c = context(style: .overlay, listeningCompact: true)
        c.screenFrame = .zero
        c.screenVisibleFrame = .zero
        let frame = DictationHUDPlacement.frame(c)
        #expect(frame == NSRect(x: 0, y: 0, width: 336, height: 64))
    }
}
