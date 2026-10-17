import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Dictation release to next capture")
struct DictationReleaseLatencyTests {
    // @unchecked: `handler` is touched only under `lock`.
    private final class Hotkey: HotkeyMonitor, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (HotkeyEvent) -> Void)?
        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async { lock.withLock { self.handler = handler } }
        func stop() async { lock.withLock { handler = nil } }
        func fire(_ event: HotkeyEvent) { lock.withLock { handler }?(event) }
    }

    private actor GatedRecorder: DictationRecorder {
        let decodeHeld: AsyncStream<Void>
        private let decodeHeldSignal: AsyncStream<Void>.Continuation
        private var starts = 0
        private let startSignal: AsyncStream<Int>.Continuation
        let startEvents: AsyncStream<Int>
        private var decodeGate: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        init() {
            (decodeHeld, decodeHeldSignal) = AsyncStream.makeStream()
            (startEvents, startSignal) = AsyncStream.makeStream()
        }

        func start() async throws {
            starts += 1
            startSignal.yield(starts)
        }

        func stopAndTranscribe() async throws -> String { try await stopCapture().finalize() }

        func stopCapture() async throws -> DictationTake {
            DictationTake(finalize: {
                await self.holdDecode()
                return "text"
            })
        }

        private func holdDecode() async {
            decodeHeldSignal.yield()
            guard !opened else { return }
            await withCheckedContinuation { decodeGate.append($0) }
        }

        func openDecode() {
            opened = true
            for waiter in decodeGate { waiter.resume() }
            decodeGate = []
        }
    }

    @Test("a press right after a release starts capturing while the previous take's decode is still held", .timeLimit(.minutes(1)))
    func nextCaptureStartsDuringTheDecode() async {
        let hotkey = Hotkey()
        let recorder = GatedRecorder()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: Inserter(), features: .all)
        await coord.startMonitoring()
        var starts = recorder.startEvents.makeAsyncIterator()
        var held = recorder.decodeHeld.makeAsyncIterator()

        hotkey.fire(.press)
        _ = await starts.next()
        hotkey.fire(.release)
        _ = await held.next()
        hotkey.fire(.press)
        let second = await starts.next()

        #expect(second == 2, "the second capture started before the first decode finished")
        await recorder.openDecode()
        hotkey.fire(.release)
        await coord.stopMonitoring()
    }

    private struct Inserter: TextInserter {
        func insert(_ text: String) async throws {}
    }
}
