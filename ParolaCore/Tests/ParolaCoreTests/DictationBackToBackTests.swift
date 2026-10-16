import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

private actor Gate {
    private var isOpen = false
    private var entered = 0
    private var holders: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        entered += 1
        let ready = enterWaiters.filter { $0.count <= entered }
        enterWaiters.removeAll { $0.count <= entered }
        for waiter in ready { waiter.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { holders.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = holders
        holders = []
        for holder in waiting { holder.resume() }
    }

    func release() {
        guard !holders.isEmpty else { return }
        holders.removeFirst().resume()
    }

    func waitEntered(_ count: Int = 1) async {
        guard entered < count else { return }
        await withCheckedContinuation { enterWaiters.append((count, $0)) }
    }
}

private final class QuietHotkey: HotkeyMonitor {
    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {}
    func stop() async {}
}

private struct ScriptedFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private actor ScriptedRecorder: DictationRecorder {
    struct Take {
        var text: String
        var finalizeGate: Gate?
        var failure: String?
    }

    private var script: [Take]
    private(set) var started: [DictationPipelineConfiguration?] = []
    private(set) var stopped = 0
    private(set) var discarded = 0
    private(set) var takesDiscarded = 0
    private var capturing = false

    init(_ script: [Take]) { self.script = script }

    func start() async throws {
        started.append(nil)
        capturing = true
    }

    func start(configuration: DictationPipelineConfiguration) async throws {
        started.append(configuration)
        capturing = true
    }

    func stopAndTranscribe() async throws -> String { try await stopCapture().finalize() }

    func stopCapture() async throws -> DictationTake {
        stopped += 1
        capturing = false
        let take = script.isEmpty ? Take(text: "") : script.removeFirst()
        return DictationTake(
            finalize: {
                await take.finalizeGate?.pass()
                if let failure = take.failure { throw ScriptedFailure(text: failure) }
                return take.text
            },
            discard: { await self.noteTakeDiscarded() }
        )
    }

    func stopAndDiscard() async {
        discarded += 1
        capturing = false
    }

    private func noteTakeDiscarded() { takesDiscarded += 1 }
}

private struct GatedProcessor: TextPostProcessor {
    let gate: Gate
    func process(_ text: String) async -> String {
        await gate.pass()
        return text
    }
}

private struct SuffixProcessor: TextPostProcessor {
    let suffix: String
    func process(_ text: String) async -> String { text + suffix }
}

private actor ScriptedInserter: TextInserter {
    private(set) var inserted: [String] = []
    private let gate: Gate?
    private(set) var boundConfigurations = 0

    init(gate: Gate? = nil) { self.gate = gate }

    func insert(_ text: String) async throws {
        await gate?.pass()
        inserted.append(text)
    }

    func bound(to configuration: DictationPipelineConfiguration?) async -> any TextInserter {
        boundConfigurations += 1
        return self
    }
}

private actor StateLog {
    private(set) var states: [DictationCoordinator.State] = []
    func record(_ state: DictationCoordinator.State) { states.append(state) }
}

@Suite("Dictation back-to-back takes")
struct DictationBackToBackTests {
    private func makeCoordinator(
        recorder: ScriptedRecorder,
        inserter: ScriptedInserter,
        processor: (any TextPostProcessor)? = nil,
        mode: DictationMode = .pushToTalk,
        provider: (@Sendable () async -> DictationPipelineConfiguration)? = nil,
        log: StateLog? = nil
    ) -> DictationCoordinator {
        DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: inserter,
            postProcessor: processor, mode: mode, configurationProvider: provider, features: .all
        ) { state in await log?.record(state) }
    }

    @Test("a press during cleanup starts capture at once", .timeLimit(.minutes(1)))
    func pressDuringCleanup() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([.init(text: "one"), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup))
        await coord.handle(.press)
        await coord.handle(.release)
        await cleanup.waitEntered()

        await coord.handle(.press)

        #expect(await coord.state == .listening)
        #expect(await recorder.started.count == 2)
        await cleanup.open()
        await coord.handle(.release)
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
        #expect(await coord.state == .idle)
    }

    @Test("a press during paste starts capture at once", .timeLimit(.minutes(1)))
    func pressDuringPaste() async {
        let paste = Gate()
        let recorder = ScriptedRecorder([.init(text: "one"), .init(text: "two")])
        let inserter = ScriptedInserter(gate: paste)
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await paste.waitEntered()

        await coord.handle(.press)

        #expect(await coord.state == .listening)
        #expect(await recorder.started.count == 2)
        await paste.open()
        await coord.handle(.release)
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
    }

    @Test("a press during the tail decode starts capture at once", .timeLimit(.minutes(1)))
    func pressDuringTailDecode() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: tail), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()

        await coord.handle(.press)

        #expect(await coord.state == .listening)
        await tail.open()
        await coord.handle(.release)
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
    }

    @Test("toggle mode: the second press ends take one and the third starts take two while one is processed", .timeLimit(.minutes(1)))
    func toggleSequence() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([.init(text: "one"), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(
            recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup), mode: .toggle
        )
        await coord.handle(.press)
        await coord.handle(.press)
        await cleanup.waitEntered()
        #expect(await coord.state == .transcribing)

        await coord.handle(.press)
        #expect(await coord.state == .listening)

        await coord.handle(.press)
        await cleanup.open()
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
    }

    @Test("a short second take finishing first still inserts after the first", .timeLimit(.minutes(1)))
    func insertsStayInOrder() async {
        let slowTail = Gate()
        let recorder = ScriptedRecorder([.init(text: "long", finalizeGate: slowTail), .init(text: "short")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await slowTail.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await coord.handle(.release)

        #expect(await inserter.inserted.isEmpty)
        await slowTail.open()
        await coord.drain()
        #expect(await inserter.inserted == ["long", "short"])
    }

    @Test("abort drops takes that are queued and not yet inserted", .timeLimit(.minutes(1)))
    func abortDropsQueuedTakes() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([.init(text: "one"), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup))
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await cleanup.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)

        await coord.abortMonitoring()
        await cleanup.open()
        await coord.drain()

        #expect(await inserter.inserted.isEmpty)
        #expect(await recorder.takesDiscarded == 2)
        #expect(await coord.state == .idle)
    }

    @Test("stop finishes the take in flight and drains every earlier one", .timeLimit(.minutes(1)))
    func stopDrains() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: tail), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()
        await coord.handle(.press)

        let stopping = Task { await coord.stopMonitoring() }
        await tail.open()
        await stopping.value

        #expect(await inserter.inserted == ["one", "two"])
        #expect(await coord.state == .idle)
    }

    @Test("a failure in take one does not block take two", .timeLimit(.minutes(1)))
    func failureDoesNotBlockTheNext() async {
        let tail = Gate()
        let log = StateLog()
        let recorder = ScriptedRecorder([
            .init(text: "", finalizeGate: tail, failure: "boom"), .init(text: "two"),
        ])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, log: log)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)

        await tail.open()
        await coord.drain()

        #expect(await inserter.inserted == ["two"])
        #expect(await coord.state == .idle)
    }

    @Test("a failure with nothing after it rests as failed", .timeLimit(.minutes(1)))
    func failureShows() async {
        let recorder = ScriptedRecorder([.init(text: "", failure: "boom")])
        let coord = makeCoordinator(recorder: recorder, inserter: ScriptedInserter())
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        #expect(await coord.state == .failed("boom"))
    }

    @Test("cancelling a take being processed leaves the next one alone", .timeLimit(.minutes(1)))
    func cancelProcessing() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: tail), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()

        #expect(await coord.abandonTranscription())
        #expect(await coord.state == .idle)

        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        await tail.open()
        #expect(await inserter.inserted == ["two"])
    }

    @Test("cancelling the capture leaves an earlier take being processed", .timeLimit(.minutes(1)))
    func cancelListeningKeepsEarlierTake() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: tail)])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()
        await coord.handle(.press)

        await coord.cancelListening()
        #expect(await coord.state == .transcribing)
        #expect(await recorder.discarded == 1)

        await tail.open()
        await coord.drain()
        #expect(await inserter.inserted == ["one"])
        #expect(await coord.state == .idle)
    }

    @Test("hybrid mode: a press during processing starts a take", .timeLimit(.minutes(1)))
    func hybridPressDuringProcessing() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([.init(text: "one"), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(
            recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup), mode: .hybrid
        )
        let down = Date()
        await coord.handle(.press, capturedAt: down)
        await coord.handle(.release, capturedAt: down.addingTimeInterval(0.6))
        await cleanup.waitEntered()

        await coord.handle(.press, capturedAt: down.addingTimeInterval(0.8))

        #expect(await coord.state == .listening)
        await cleanup.open()
        await coord.handle(.release, capturedAt: down.addingTimeInterval(1.5))
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
    }

    @Test("each press reads the configuration and a take keeps the one it started with", .timeLimit(.minutes(1)))
    func configurationPerPress() async {
        let counter = Counter()
        let recorder = ScriptedRecorder([.init(text: "a"), .init(text: "b")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, provider: {
            let n = counter.next()
            return DictationPipelineConfiguration(language: "l\(n)", postProcessor: SuffixProcessor(suffix: "\(n)"))
        })
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()

        #expect(await recorder.started.map { $0?.language } == ["l1", "l2"])
        #expect(await inserter.inserted == ["a1", "b2"])
        #expect(await inserter.boundConfigurations == 2)
    }
}

private final class Counter: Sendable {
    private let value = NSLock()
    nonisolated(unsafe) private var current = 0
    func next() -> Int {
        value.withLock {
            current += 1
            return current
        }
    }
}
