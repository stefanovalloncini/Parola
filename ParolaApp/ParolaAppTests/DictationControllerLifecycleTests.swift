import AppKit
import Carbon.HIToolbox
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

private struct MeteredRecorder: DictationRecorder {
    let meter: LevelMeter
    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "" }
    func levelMeter() async -> LevelMeter? { meter }
}

/// Holds its final until released, and remembers whether the flush was cancelled on the way.
private actor HeldFlushRecorder: DictationRecorder {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var holding = false
    private(set) var finishedCancelled: Bool?

    func start() async throws {}

    func stopAndTranscribe() async throws -> String {
        holding = true
        await withCheckedContinuation { gate = $0 }
        finishedCancelled = Task.isCancelled
        return ""
    }

    func stopAndDiscard() async {}

    func release() {
        gate?.resume()
        gate = nil
    }
}

private struct BusyMicRecorder: DictationRecorder {
    struct Busy: LocalizedError {
        var errorDescription: String? { "The microphone is in use by another app." }
    }

    func start() async throws { throw Busy() }
    func stopAndTranscribe() async throws -> String { "" }
}

/// Hears "hello" and remembers whether its take was thrown away instead of transcribed.
private actor SpeakingRecorder: DictationRecorder {
    private(set) var discarded = false

    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "hello" }
    func stopAndDiscard() async { discarded = true }
}

/// Every line the controller said to VoiceOver, with its priority.
@MainActor
private final class SpokenLines {
    var lines: [(text: String, priority: NSAccessibilityPriorityLevel)] = []
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

    @Test("a failure's HUD stays up until it is dismissed", .timeLimit(.minutes(1)))
    func failureStaysUntilDismissed() async {
        let log = MonitorLog()
        let controller = DictationController()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: 1, log: log) }
        controller.recorderFactory = { _ in BusyMicRecorder() }
        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)

        controller.simulatePress()
        await waitUntil {
            guard case .failed = controller.state else { return false }
            return true
        }
        await settle(for: .seconds(3.5))
        #expect(controller.hudIsUp, "the reason left before it could be read")

        controller.dismissFailure()
        await waitUntil { controller.state == .idle }
        #expect(!controller.hudIsUp)
        controller.stop()
    }

    @Test("Escape dismisses a failed HUD", .timeLimit(.minutes(1)))
    func escapeDismissesFailure() async {
        let log = MonitorLog()
        let controller = DictationController()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: 1, log: log) }
        controller.recorderFactory = { _ in BusyMicRecorder() }
        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)

        controller.simulatePress()
        await waitUntil {
            guard case .failed = controller.state else { return false }
            return true
        }
        #expect(controller.hudIsUp)

        controller.cancelDictation()

        await waitUntil { controller.state == .idle }
        #expect(!controller.hudIsUp)
        controller.stop()
    }

    @Test("VoiceOver hears dictation listen, transcribe and fail")
    func dictationIsAnnounced() async {
        let log = MonitorLog()
        let controller = DictationController()
        let spoken = SpokenLines()
        controller.speak = { spoken.lines.append(($0, $1)) }
        let store = CapturedInsertionStore()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: 1, log: log) }
        controller.recorderFactory = { _ in SpeakingRecorder() }
        controller.inserterFactory = { CapturingTextInserter(store: store) }
        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)

        controller.simulatePress()
        await waitUntil { controller.state == .listening }
        controller.simulateRelease()
        await waitUntil { store.all() == ["hello"] }

        #expect(spoken.lines.map(\.text) == ["Listening", "Transcribing"])
        controller.stop()

        let failing = DictationController()
        failing.speak = { spoken.lines.append(($0, $1)) }
        spoken.lines = []
        failing.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: 2, log: log) }
        failing.recorderFactory = { _ in BusyMicRecorder() }
        failing.start(configuration: makeConfiguration())
        await log.waitForOps(4)
        failing.simulatePress()
        await waitUntil { spoken.lines.count == 1 }
        #expect(spoken.lines.first?.text == "The microphone is in use by another app.")
        #expect(spoken.lines.first?.priority == .high)
        failing.stop()
    }

    @Test("Escape drops what is being said, pastes nothing and arms again")
    func escapeCancels() async {
        let log = MonitorLog()
        let controller = DictationController()
        let recorder = SpeakingRecorder()
        let store = CapturedInsertionStore()
        let counter = Counter()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: counter.next(), log: log) }
        controller.recorderFactory = { _ in recorder }
        controller.inserterFactory = { CapturingTextInserter(store: store) }
        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)
        controller.simulatePress()
        await waitUntil { controller.state == .listening }

        controller.cancelDictation()

        #expect(controller.state == .idle)
        await waitUntil { await recorder.discarded }
        await settle()
        #expect(store.all().isEmpty)
        #expect(controller.isRunning, "dictation stays armed for the next press")
        controller.stop()
    }

    @Test("a modified or repeated Escape does not cancel dictation")
    func modifiedOrRepeatedEscapeIsIgnored() throws {
        let escape = UInt16(kVK_Escape)
        let plain = try #require(Self.keyEvent(keyCode: escape, modifierFlags: [], isARepeat: false))
        let withCommand = try #require(Self.keyEvent(keyCode: escape, modifierFlags: .command, isARepeat: false))
        let repeated = try #require(Self.keyEvent(keyCode: escape, modifierFlags: [], isARepeat: true))

        #expect(DictationController.isPlainEscape(plain))
        #expect(!DictationController.isPlainEscape(withCommand))
        #expect(!DictationController.isPlainEscape(repeated))
    }

    private static func keyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, isARepeat: Bool) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: isARepeat, keyCode: keyCode
        )
    }

    @Test("the HUD reads the listening take's meter and lets go of it when listening ends")
    func hudReadsTheTakeMeter() async {
        let log = MonitorLog()
        let controller = DictationController()
        let meter = LevelMeter()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: 1, log: log) }
        controller.recorderFactory = { _ in MeteredRecorder(meter: meter) }

        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)
        controller.simulatePress()
        await waitUntil { controller.levelMeter === meter }

        controller.simulateRelease()
        await waitUntil { controller.levelMeter == nil }
        controller.stop()
    }

    @Test("a restart arms the next monitor after the bound, and the old flush still finishes uncancelled")
    func restartDoesNotCancelTheLastUtterance() async {
        let log = MonitorLog()
        let controller = DictationController()
        let counter = Counter()
        let held = HeldFlushRecorder()
        controller.hotkeyFactory = { _, _ in SpyHotkeyMonitor(id: counter.next(), log: log) }
        controller.recorderFactory = { _ in held }
        controller.teardownBound = .milliseconds(50)

        controller.start(configuration: makeConfiguration())
        await log.waitForOps(2)
        controller.simulatePress()
        var spins = 0
        while controller.state != .listening, spins < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        #expect(controller.state == .listening)

        controller.stop()
        controller.start(configuration: makeConfiguration())
        await log.waitForOps(5)
        #expect(await held.holding, "the old session's final is still being flushed")

        await held.release()
        spins = 0
        while await held.finishedCancelled == nil, spins < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        #expect(await held.finishedCancelled == false)
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
