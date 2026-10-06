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

    private var fieldAnchor: FieldAnchor {
        FieldAnchor(
            rect: NSRect(x: 400, y: 500, width: 220, height: 24),
            source: .field,
            screenFrame: screenFrame,
            screenVisibleFrame: visibleFrame
        )
    }

    @Test("near field sits below the anchor")
    func nearFieldBelow() {
        let frame = DictationHUDPlacement.frame(context(style: .nearField, anchor: fieldAnchor))
        #expect(frame == NSRect(x: 400, y: 500 - 8 - 44, width: 200, height: 44))
    }

    @Test("near field flips above when the screen bottom would clip it")
    func nearFieldFlipsAbove() {
        var anchor = fieldAnchor
        anchor.rect = NSRect(x: 400, y: 30, width: 220, height: 24)
        let frame = DictationHUDPlacement.frame(context(style: .nearField, anchor: anchor))
        // #expect misreads a bare multi-term integer sum as Int and fails the CGFloat comparison; the cast pins its type.
        #expect(frame.origin.y == CGFloat(30 + 24 + 8))
    }

    @Test("near field clamps into the anchor's screen")
    func nearFieldClampsRight() {
        var anchor = fieldAnchor
        anchor.rect = NSRect(x: 1400, y: 500, width: 100, height: 24)
        let frame = DictationHUDPlacement.frame(context(style: .nearField, anchor: anchor))
        #expect(frame.origin.x == CGFloat(1512 - 200 - 8))
    }

    @Test("near field grows for partial text and failure messages")
    func nearFieldExpanded() {
        let partial = DictationHUDPlacement.frame(context(style: .nearField, hasPartial: true, anchor: fieldAnchor))
        #expect(partial.size == NSSize(width: 360, height: 96))
        let failed = DictationHUDPlacement.frame(context(style: .nearField, failedMessageVisible: true, anchor: fieldAnchor))
        #expect(failed.size == NSSize(width: 360, height: 96))
    }

    @Test("every style grows to show a failure's reason, and the minimal dot stays in its corner")
    func everyStyleShowsTheFailure() {
        let overlay = DictationHUDPlacement.frame(context(style: .overlay, failedMessageVisible: true))
        #expect(overlay.size == NSSize(width: 380, height: 84))
        let notch = DictationHUDPlacement.frame(context(style: .notch, failedMessageVisible: true))
        #expect(notch.size == NSSize(width: 372, height: 52))
        let minimal = DictationHUDPlacement.frame(context(style: .minimal, failedMessageVisible: true))
        #expect(minimal == NSRect(x: 1512 - 360 - 24, y: 24, width: 360, height: 96))
    }

    @Test("near field without an anchor falls back to the overlay spot")
    func nearFieldFallback() {
        let frame = DictationHUDPlacement.frame(context(style: .nearField))
        #expect(frame == NSRect(x: 756 - 100, y: 100, width: 200, height: 44))
    }

    @Test("near field on a second display clamps to that display")
    func nearFieldSecondDisplay() {
        var anchor = fieldAnchor
        anchor.rect = NSRect(x: 3300, y: 500, width: 100, height: 24)
        anchor.screenFrame = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        anchor.screenVisibleFrame = NSRect(x: 1512, y: 0, width: 1920, height: 1055)
        let frame = DictationHUDPlacement.frame(context(style: .nearField, anchor: anchor))
        #expect(frame.origin.x == CGFloat(1512 + 1920 - 200 - 8))
        #expect(frame.origin.y == CGFloat(500 - 8 - 44))
    }
}
