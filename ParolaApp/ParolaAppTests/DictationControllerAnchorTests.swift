import Foundation
import Testing
@testable import Parola

@Suite("Dictation controller anchor")
@MainActor
struct DictationControllerAnchorTests {
    private struct MockProvider: FieldAnchorProviding {
        var anchor: FieldAnchor?
        func currentAnchor(on geometry: ScreenGeometry) -> FieldAnchor? { anchor }
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
    func refreshStoresAnchor() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        #expect(await controller.refreshAnchor() == true)
        #expect(controller.currentAnchor == anchor)
    }

    @Test("refreshAnchor reports no change when the anchor is stable")
    func refreshDetectsNoChange() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        _ = await controller.refreshAnchor()
        #expect(await controller.refreshAnchor() == false)
    }

    @Test("other styles never hold an anchor")
    func otherStylesClearAnchor() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = MockProvider(anchor: anchor)
        _ = await controller.refreshAnchor()
        controller.indicatorStyle = .overlay
        #expect(await controller.refreshAnchor() == true)
        #expect(controller.currentAnchor == nil)
    }

    @Test("fresh defaults resolve to the near-field style")
    func nearFieldIsDefault() {
        #expect(DictationIndicatorStyle(rawValue: "nearField") == .nearField)
        #expect(DictationIndicatorStyle.allCases.first == .nearField)
    }

    private final class SlowProvider: FieldAnchorProviding, @unchecked Sendable {
        let anchor: FieldAnchor?
        let delay: TimeInterval
        private let lock = NSLock()
        private var onMain: [Bool] = []
        init(anchor: FieldAnchor?, delay: TimeInterval) { self.anchor = anchor; self.delay = delay }
        var probes: [Bool] { lock.withLock { onMain } }
        func currentAnchor(on geometry: ScreenGeometry) -> FieldAnchor? {
            lock.withLock { onMain.append(Thread.isMainThread) }
            Thread.sleep(forTimeInterval: delay)
            return anchor
        }
    }

    @Test("a slow probe runs off the main thread and leaves the main actor free")
    func probeDoesNotBlockMain() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        let provider = SlowProvider(anchor: anchor, delay: 0.4)
        controller.anchorProvider = provider
        let started = ContinuousClock.now
        let refresh = Task { @MainActor in await controller.refreshAnchor() }
        var ticks = 0
        while ContinuousClock.now - started < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(10))
            ticks += 1
        }
        #expect(ticks >= 15)
        #expect(await refresh.value == true)
        #expect(provider.probes == [false])
    }

    @Test("a probe already running absorbs the next request")
    func overlappingRefreshSkips() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        let provider = SlowProvider(anchor: anchor, delay: 0.2)
        controller.anchorProvider = provider
        async let first = controller.refreshAnchor()
        try? await Task.sleep(for: .milliseconds(50))
        let second = await controller.refreshAnchor()
        #expect(second == false)
        #expect(await first == true)
        #expect(provider.probes.count == 1)
    }

    @Test("an anchor that lands after the HUD was dismissed is dropped")
    func staleResultDiscarded() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        controller.anchorProvider = SlowProvider(anchor: anchor, delay: 0.2)
        async let result = controller.refreshAnchor()
        try? await Task.sleep(for: .milliseconds(50))
        controller.stop()
        #expect(await result == false)
        #expect(controller.currentAnchor == nil)
    }
}
