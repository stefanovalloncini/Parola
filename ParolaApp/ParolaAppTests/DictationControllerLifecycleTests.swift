import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

private actor MonitorLog {
    private(set) var ops: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ op: String) {
        ops.append(op)
        let ready = waiters.filter { $0.count <= ops.count }
        waiters.removeAll { $0.count <= ops.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForOps(_ count: Int) async {
        if ops.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

/// Suspends inside `stop()` so a racing teardown gets a chance to interleave with a
/// still-running `startMonitoring` — the schedule that orphaned real NSEvent monitors.
private final class SpyHotkeyMonitor: HotkeyMonitor {
    let id: Int
    let log: MonitorLog
    init(id: Int, log: MonitorLog) {
        self.id = id
        self.log = log
    }

    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
        await log.record("start\(id)")
    }

    func stop() async {
        for _ in 0..<3 { await Task.yield() }
        await log.record("stop\(id)")
    }
}

private struct StubRecorder: DictationRecorder {
    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "" }
}

private struct IdentityPostProcessor: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}

@MainActor
@Suite("Dictation controller lifecycle")
struct DictationControllerLifecycleTests {
    private func makeConfiguration() -> DictationController.Configuration {
        DictationController.Configuration(
            modelName: "openai_whisper-tiny",
            language: nil,
            deviceUID: nil,
            streamingEnabled: false,
            hotkeyKeyCode: 96,
            mode: .pushToTalk,
            workflows: [:],
            postProcessor: IdentityPostProcessor()
        )
    }

    @Test("restart tears the old hotkey monitor down before arming the next")
    func restartSerializesMonitorLifecycle() async {
        let log = MonitorLog()
        let controller = DictationController()
        let counter = Counter()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: counter.next(), log: log) }
        controller.recorderFactory = { _ in StubRecorder() }

        controller.start(configuration: makeConfiguration())
        controller.stop()
        controller.start(configuration: makeConfiguration())

        // Fully drained: startMonitoring(C1)=[stop1,start1], stopMonitoring(C1)=[stop1],
        // startMonitoring(C2)=[stop2,start2] — five ops regardless of interleaving.
        await log.waitForOps(5)
        let ops = await log.ops

        let lastStart1 = ops.lastIndex(of: "start1")
        let lastStop1 = ops.lastIndex(of: "stop1")
        #expect(lastStart1 != nil && lastStop1 != nil, "monitor 1 never cycled: \(ops)")
        if let lastStart1, let lastStop1 {
            #expect(lastStart1 < lastStop1, "old monitor left armed after teardown: \(ops)")
        }
        #expect(ops.last == "start2", "live monitor should arm last: \(ops)")

        controller.stop()
    }
}

@MainActor
private final class Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
