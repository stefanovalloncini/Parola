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

    private final class GatedProvider: FieldAnchorProviding, @unchecked Sendable {
        let anchor: FieldAnchor?
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var onMain: [Bool] = []

        init(anchor: FieldAnchor?) {
            self.anchor = anchor
            (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        var probes: [Bool] { lock.withLock { onMain } }
        func open() { gate.signal() }

        func currentAnchor(on geometry: ScreenGeometry) -> FieldAnchor? {
            lock.withLock { onMain.append(Thread.isMainThread) }
            startedContinuation.yield()
            gate.wait()
            return anchor
        }
    }

    @Test("a blocked probe runs off the main thread and leaves the main actor free")
    func probeDoesNotBlockMain() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        let provider = GatedProvider(anchor: anchor)
        controller.anchorProvider = provider
        let refresh = Task { @MainActor in await controller.refreshAnchor() }
        var started = provider.started.makeAsyncIterator()
        await started.next()
        await MainActor.run {}
        #expect(controller.currentAnchor == nil)
        provider.open()
        #expect(await refresh.value == true)
        #expect(provider.probes == [false])
    }

    @Test("a request during a probe runs one more probe after it")
    func overlappingRefreshReprobes() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        let provider = GatedProvider(anchor: anchor)
        controller.anchorProvider = provider
        let first = Task { @MainActor in await controller.refreshAnchor() }
        var started = provider.started.makeAsyncIterator()
        await started.next()
        let second = Task { @MainActor in await controller.refreshAnchor() }
        await MainActor.run {}
        provider.open()
        await started.next()
        provider.open()
        #expect(await first.value == true)
        #expect(await second.value == true)
        #expect(provider.probes.count == 2)
    }

    @Test("an anchor that lands after the HUD was dismissed is dropped")
    func staleResultDiscarded() async {
        let controller = DictationController()
        controller.indicatorStyle = .nearField
        let provider = GatedProvider(anchor: anchor)
        controller.anchorProvider = provider
        let result = Task { @MainActor in await controller.refreshAnchor() }
        var started = provider.started.makeAsyncIterator()
        await started.next()
        controller.stop()
        provider.open()
        #expect(await result.value == false)
        #expect(controller.currentAnchor == nil)
    }
}
