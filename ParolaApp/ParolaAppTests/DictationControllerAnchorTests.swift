import Foundation
import Testing
@testable import Parola

@Suite("Dictation controller anchor")
@MainActor
struct DictationControllerAnchorTests {
    private struct MockProvider: FieldAnchorProviding {
        var anchor: FieldAnchor?
        func currentAnchor() -> FieldAnchor? { anchor }
    }

    private var anchor: FieldAnchor {
        FieldAnchor(
            rect: NSRect(x: 400, y: 500, width: 220, height: 24),
            source: .caret,
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            screenVisibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944)
        )
    }

    @Test("refreshAnchor stores the provider's anchor for the near-field style")
    func refreshStoresAnchor() {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        #expect(controller.refreshAnchor() == true)
        #expect(controller.currentAnchor == anchor)
    }

    @Test("refreshAnchor reports no change when the anchor is stable")
    func refreshDetectsNoChange() {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        _ = controller.refreshAnchor()
        #expect(controller.refreshAnchor() == false)
    }

    @Test("other styles never hold an anchor")
    func otherStylesClearAnchor() {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        _ = controller.refreshAnchor()
        controller.indicatorStyle = .overlay
        #expect(controller.refreshAnchor() == true)
        #expect(controller.currentAnchor == nil)
    }

    @Test("fresh defaults resolve to the near-field style")
    func nearFieldIsDefault() {
        #expect(DictationIndicatorStyle(rawValue: "nearField") == .nearField)
        #expect(DictationIndicatorStyle.allCases.first == .nearField)
    }
}
