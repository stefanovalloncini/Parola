import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Dictation coordinator")
struct DictationCoordinatorTests {
    private actor MockHotkey: HotkeyMonitor {
        var handler: (@Sendable (HotkeyEvent) -> Void)?

        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
            self.handler = handler
        }

        func stop() async {
            handler = nil
        }

        func fire(_ event: HotkeyEvent) async {
            handler?(event)
        }
    }

    private actor MockRecorder: DictationRecorder {
        enum Outcome: Sendable {
            case text(String)
            case failure(String)
        }

        var startCalls = 0
        var stopCalls = 0
        var outcome: Outcome

        init(outcome: Outcome) { self.outcome = outcome }

        func start() async throws {
            startCalls += 1
        }

        func stopAndTranscribe() async throws -> String {
            stopCalls += 1
            switch outcome {
            case .text(let t): return t
            case .failure(let msg):
                struct E: Error, LocalizedError { let msg: String; var errorDescription: String? { msg } }
                throw E(msg: msg)
            }
        }
    }

    private actor MockInserter: TextInserter {
        var inserted: [String] = []
        func insert(_ text: String) async {
            inserted.append(text)
        }
    }

    @Test("press starts recording and transitions to listening")
    func pressStartsRecording() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)
        let starts = await recorder.startCalls
        #expect(starts == 1)
    }

    @Test("release triggers transcribe and paste, then returns to idle")
    func releaseFinishes() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello world"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["hello world"])
    }

    @Test("press while listening is ignored")
    func pressWhileListening() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hi"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.press)
        let starts = await recorder.startCalls
        #expect(starts == 1)
    }

    @Test("release without preceding press is ignored")
    func releaseWithoutPress() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hi"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.release)
        let stops = await recorder.stopCalls
        #expect(stops == 0)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    private actor StateRecorder {
        var captured: [DictationCoordinator.State] = []
        func record(_ s: DictationCoordinator.State) { captured.append(s) }
    }

    @Test("transcriber failure returns to idle with failed state observed")
    func transcribeFailure() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .failure("mic error"))
        let inserter = MockInserter()
        let stateRecorder = StateRecorder()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter
        ) { state in
            await stateRecorder.record(state)
        }
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
        let captured = await stateRecorder.captured
        #expect(captured.contains(where: {
            if case .failed = $0 { return true } else { return false }
        }))
    }

    @Test("empty transcript text is not inserted")
    func emptyTextSkipped() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("   "))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    private struct UppercasePostProcessor: TextPostProcessor {
        func process(_ text: String) async -> String { text.uppercased() }
    }

    private struct EmptyingPostProcessor: TextPostProcessor {
        func process(_ text: String) async -> String { "" }
    }

    private struct CursorMarkerPostProcessor: TextPostProcessor {
        func process(_ text: String) async -> String { "\(text) \(SnippetMarker.cursor) tail" }
    }

    @Test("the {{CURSOR}} sentinel is stripped before insertion")
    func cursorMarkerStrippedBeforeInsert() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: CursorMarkerPostProcessor()
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        let inserted = await inserter.inserted
        #expect(inserted.count == 1)
        #expect(inserted.first?.contains(SnippetMarker.cursor) == false)
        #expect(inserted.first?.contains("__PAROLA_CURSOR__") == false)
        #expect(inserted.first?.contains("hello") == true)
    }

    @Test("post-processor transforms text before inserting")
    func postProcessorTransforms() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello world"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: UppercasePostProcessor()
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        let inserted = await inserter.inserted
        #expect(inserted == ["HELLO WORLD"])
    }

    @Test("toggle mode: press starts, second press stops and transcribes")
    func toggleMode() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("toggled"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            mode: .toggle
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)
        await coord.handle(.release)
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["toggled"])
    }

    @Test("hybrid mode: quick tap toggles, hold acts as PTT")
    func hybridMode() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hybrid"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            mode: .hybrid
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        await coord.handle(.release)
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["hybrid"])
    }

    @Test("hybrid mode: tap then hold-and-release closes via release path")
    func hybridTapThenHold() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("held"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            mode: .hybrid
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        try await Task.sleep(for: .milliseconds(350))
        await #expect(coord.state == .listening)
        await coord.handle(.release)
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["held"])
    }

    @Test("setMode resets pending hybrid state")
    func setModeResetsHybrid() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("x"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            mode: .hybrid
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.setMode(.pushToTalk)
        await coord.handle(.release)
        await #expect(coord.state == .idle)
    }

    @Test("stopMonitoring flushes in-flight recording instead of dropping it")
    func stopMonitoringFlushes() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("flushed"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.stopMonitoring()
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["flushed"])
    }

    @Test("abortMonitoring discards in-flight recording")
    func abortMonitoringDiscards() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("dropped"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.abortMonitoring()
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    @Test("post-processor that returns empty text skips insertion")
    func postProcessorEmptyOutputSkips() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: EmptyingPostProcessor()
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    /// A recorder whose `start()` parks until the test opens the gate, so a teardown can be
    /// injected while `beginListening` is mid-startup.
    private actor GatedRecorder: DictationRecorder {
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        private(set) var running = false
        private(set) var gateArmed = false
        private var gate: CheckedContinuation<Void, Never>?

        func start() async throws {
            startCalls += 1
            await withCheckedContinuation { gate = $0; gateArmed = true }
            running = true
        }

        func openGate() {
            gateArmed = false
            gate?.resume()
            gate = nil
        }

        func stopAndTranscribe() async throws -> String {
            stopCalls += 1
            running = false
            return ""
        }
    }

    @Test("aborting while a press is mid-startup never leaves the recorder running")
    func abortDuringStartupDoesNotOrphanRecorder() async throws {
        let hotkey = MockHotkey()
        let recorder = GatedRecorder()
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()

        let press = Task { await coord.simulatePress() }

        var spins = 0
        while await recorder.gateArmed == false {
            await Task.yield()
            spins += 1
            if spins > 100_000 { break }
        }

        await coord.abortMonitoring()
        await recorder.openGate()
        await press.value

        await #expect(coord.state == .idle)
        let running = await recorder.running
        #expect(running == false, "recorder must be stopped, not orphaned, after abort races startup")
    }
}
