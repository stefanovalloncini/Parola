import Foundation
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
}
