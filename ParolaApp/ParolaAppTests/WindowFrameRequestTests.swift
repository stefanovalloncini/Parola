import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola

@Suite("setWindowFrame arguments")
struct WindowFrameRequestTests {

    private let current = CGRect(x: 100, y: 200, width: 1_180, height: 800)

    @Test("a full request replaces the frame")
    func fullRequest() throws {
        let frame = try WindowFrameRequest.resolve(current: current, x: 0, y: 40, w: 920, h: 600)
        #expect(frame == CGRect(x: 0, y: 40, width: 920, height: 600))
    }

    @Test("omitted fields keep what the window already has")
    func partialRequest() throws {
        let frame = try WindowFrameRequest.resolve(current: current, x: nil, y: nil, w: 920, h: nil)
        #expect(frame == CGRect(x: 100, y: 200, width: 920, height: 800))
    }

    @Test("a size of zero or less is rejected instead of collapsing the window")
    func rejectsNonPositiveSize() {
        #expect(throws: AutomationError.self) {
            _ = try WindowFrameRequest.resolve(current: current, x: nil, y: nil, w: 0, h: nil)
        }
        #expect(throws: AutomationError.self) {
            _ = try WindowFrameRequest.resolve(current: current, x: nil, y: nil, w: nil, h: -10)
        }
    }

    @Test("a negative origin is allowed: a window may sit left of the primary screen")
    func allowsNegativeOrigin() throws {
        let frame = try WindowFrameRequest.resolve(current: current, x: -400, y: 0, w: nil, h: nil)
        #expect(frame.origin.x == -400)
    }

    @Test("the answer is the frame that landed: the content's minimum width clamps a narrower ask, as in the main window")
    @MainActor
    func answersTheLandedFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 1_180, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: Color.clear.frame(
            minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight
        ))
        defer { window.contentViewController = nil }

        let narrow = WindowFrameRequest.apply(CGRect(x: -12_000, y: -12_000, width: 860, height: 700), to: window)
        #expect(narrow.width == MainWindowLayout.minimumWidth)
        #expect(narrow == window.frame)

        let wide = WindowFrameRequest.apply(CGRect(x: -12_000, y: -12_000, width: 1_000, height: 700), to: window)
        #expect(wide.width == 1_000)
        #expect(wide.height == 700)
    }
}
