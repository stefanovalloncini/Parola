import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Dictation release to next capture")
struct DictationReleaseLatencyTests {
    private final class Hotkey: HotkeyMonitor, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (HotkeyEvent) -> Void)?
        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async { lock.withLock { self.handler = handler } }
        func stop() async { lock.withLock { handler = nil } }
        func fire(_ event: HotkeyEvent) { lock.withLock { handler }?(event) }
    }

    private actor TimedRecorder: DictationRecorder {
        let decode: Duration
        private(set) var startTimes: [ContinuousClock.Instant] = []
        private var starts: AsyncStream<Int>.Continuation?
        let startSignals: AsyncStream<Int>

        init(decode: Duration) {
            self.decode = decode
            let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
            startSignals = stream
            starts = continuation
        }

        func start() async throws {
            startTimes.append(.now)
            starts?.yield(startTimes.count)
        }

        func stopAndTranscribe() async throws -> String {
            try await Task.sleep(for: decode)
            return "text"
        }
    }

    private struct SlowProcessor: TextPostProcessor {
        let delay: Duration
        func process(_ text: String) async -> String {
            try? await Task.sleep(for: delay)
            return text
        }
    }

    private struct SlowInserter: TextInserter {
        let delay: Duration
        func insert(_ text: String) async throws { try? await Task.sleep(for: delay) }
    }

    @Test("a press right after a release starts capturing well before the previous take is inserted", .timeLimit(.minutes(1)))
    func nextCaptureStartsEarly() async throws {
        let pipeline = Duration.milliseconds(900)
        let hotkey = Hotkey()
        let recorder = TimedRecorder(decode: .milliseconds(300))
        let coord = DictationCoordinator(
            hotkey: hotkey, recorder: recorder, inserter: SlowInserter(delay: .milliseconds(200)),
            postProcessor: SlowProcessor(delay: .milliseconds(400)), features: .all
        )
        await coord.startMonitoring()

        hotkey.fire(.press)
        var starts = recorder.startSignals.makeAsyncIterator()
        _ = await starts.next()
        let releasedAt = ContinuousClock.now
        hotkey.fire(.release)
        hotkey.fire(.press)
        _ = await starts.next()
        let secondStart = await recorder.startTimes[1]
        let latency = releasedAt.duration(to: secondStart)
        print("release to next capture: \(latency)")

        #expect(latency < pipeline / 2)
        hotkey.fire(.release)
        await coord.stopMonitoring()
    }
}
