import Foundation
import os
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
        var stopGate: Gate?
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
        await take.stopGate?.pass()
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

    init(gate: Gate? = nil) { self.gate = gate }

    func insert(_ text: String) async throws {
        await gate?.pass()
        inserted.append(text)
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
        targetProvider: (@Sendable (DictationPipelineConfiguration) async -> DictationTarget?)? = nil,
        log: StateLog? = nil
    ) -> DictationCoordinator {
        DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: inserter,
            postProcessor: processor, mode: mode, configurationProvider: provider,
            targetProvider: targetProvider, features: .all
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
        #expect(await coord.state == .failed("boom"), "a later success must not hide the failure")
        #expect(await log.states.contains(.failed("boom")))
    }

    @Test("a failure nobody has seen survives a third press", .timeLimit(.minutes(1)))
    func unseenFailureSurvivesAPress() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([
            .init(text: "", finalizeGate: tail, failure: "boom"), .init(text: "two"), .init(text: "three"),
        ])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await tail.open()
        await coord.handle(.release)
        await coord.drain()

        #expect(await inserter.inserted == ["two", "three"])
        #expect(await coord.state == .failed("boom"))
    }

    @Test("a press clears a failure once the HUD has shown it", .timeLimit(.minutes(1)))
    func shownFailureIsClearedByAPress() async {
        let recorder = ScriptedRecorder([.init(text: "", failure: "boom"), .init(text: "two")])
        let coord = makeCoordinator(recorder: recorder, inserter: ScriptedInserter())
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        #expect(await coord.state == .failed("boom"))

        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
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
    }
}

private actor SingleSlotRecorder: DictationRecorder {
    private var capturing = false
    private var takes = 0
    private(set) var realStarts = 0
    private(set) var discards = 0

    func start() async throws {
        guard !capturing else { return }
        capturing = true
        realStarts += 1
        takes += 1
    }

    func stopAndTranscribe() async throws -> String { "" }

    func stopCapture() async throws -> DictationTake {
        guard capturing else { return DictationTake(finalize: { "" }) }
        capturing = false
        let text = "take\(takes)"
        return DictationTake(finalize: { text })
    }

    func stopAndDiscard() async {
        guard capturing else { return }
        capturing = false
        discards += 1
    }
}

private actor HoldOnce {
    private var used = false
    private var opened = false
    private var holder: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func hold() async {
        guard !used else { return }
        used = true
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !opened else { return }
        await withCheckedContinuation { holder = $0 }
    }

    func waitEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() {
        opened = true
        holder?.resume()
        holder = nil
    }
}

extension DictationBackToBackTests {
    @Test("an abandon that lands while the release is still stopping the capture leaks nothing", .timeLimit(.minutes(1)))
    func abandonDuringStop() async {
        let stop = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", stopGate: stop)])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        let releasing = Task { await coord.handle(.release) }
        await stop.waitEntered()
        #expect(await coord.state == .transcribing)

        #expect(await coord.abandonTranscription())
        await stop.open()
        await releasing.value
        await coord.drain()

        #expect(await coord.state == .idle)
        #expect(await inserter.inserted.isEmpty)
        #expect(await recorder.takesDiscarded == 1)
        await coord.handle(.press)
        #expect(await coord.state == .listening)
    }

    @Test("an abort that lands while the release is still stopping the capture discards the take", .timeLimit(.minutes(1)))
    func abortDuringStop() async {
        let stop = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", stopGate: stop)])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        let releasing = Task { await coord.handle(.release) }
        await stop.waitEntered()

        await coord.abortMonitoring()
        await stop.open()
        await releasing.value
        await coord.drain()

        #expect(await coord.state == .idle)
        #expect(await inserter.inserted.isEmpty)
        #expect(await recorder.takesDiscarded == 1)
    }

    @Test("an abandon or abort while the take's target is still being read leaks nothing", .timeLimit(.minutes(1)), arguments: [true, false])
    func dropDuringTargetRead(abort: Bool) async {
        let targetRead = Gate()
        let recorder = ScriptedRecorder([.init(text: "one")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(
            recorder: recorder, inserter: inserter,
            provider: { DictationPipelineConfiguration(postProcessor: SuffixProcessor(suffix: ""), bind: { _ in
                DictationTakeBinding(postProcessor: SuffixProcessor(suffix: ""), inserter: inserter)
            }) },
            targetProvider: { _ in
                await targetRead.pass()
                return DictationTarget(processID: 1)
            }
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await targetRead.waitEntered()

        if abort {
            await coord.abortMonitoring()
        } else {
            #expect(await coord.abandonTranscription())
        }
        await targetRead.open()
        await coord.drain()

        #expect(await coord.state == .idle)
        #expect(await inserter.inserted.isEmpty)
    }

    @Test("a press while a Stop-button finish is publishing still captures its own take", .timeLimit(.minutes(1)))
    func pressDuringStopPublish() async {
        let hold = HoldOnce()
        let store = ScriptedInserter()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: store, mode: .toggle, features: .all
        ) { state in if state == .transcribing { await hold.hold() } }
        await coord.handle(.press)
        let stopping = Task { await coord.stopListening() }
        await hold.waitEntered()
        await coord.handle(.press)
        await hold.open()
        await stopping.value
        await coord.handle(.press)
        await coord.drain()

        #expect(await recorder.realStarts == 2)
        #expect(await store.inserted == ["take1", "take2"])
    }

    @Test("a press while Escape's cancel is publishing still captures its own take", .timeLimit(.minutes(1)))
    func pressDuringCancelPublish() async {
        let hold = HoldOnce()
        let store = ScriptedInserter()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: store, features: .all
        ) { state in if state == .idle { await hold.hold() } }
        await coord.handle(.press)
        let cancelling = Task { await coord.cancelListening() }
        await hold.waitEntered()
        await coord.handle(.press)
        await hold.open()
        await cancelling.value
        await coord.handle(.release)
        await coord.drain()

        #expect(await recorder.realStarts == 2)
        #expect(await recorder.discards == 1)
        #expect(await store.inserted == ["take2"])
    }

    @Test("giving up on the take being processed leaves the queued ones running", .timeLimit(.minutes(1)))
    func abandonKeepsQueuedTakes() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: tail), .init(text: "two")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)

        #expect(await coord.abandonTranscription())
        await coord.drain()

        #expect(await inserter.inserted == ["two"])
        await tail.open()
    }

    @Test("a take is processed and inserted with the binding built from its own target", .timeLimit(.minutes(1)))
    func bindingFollowsTheTarget() async {
        let inserted = ScriptedInserter()
        let counter = Counter()
        let recorder = ScriptedRecorder([.init(text: "a"), .init(text: "b")])
        let coord = makeCoordinator(
            recorder: recorder, inserter: ScriptedInserter(),
            provider: {
                DictationPipelineConfiguration(postProcessor: SuffixProcessor(suffix: "!"), bind: { target in
                    DictationTakeBinding(
                        postProcessor: SuffixProcessor(suffix: "@\(target?.bundleID ?? "none")"), inserter: inserted
                    )
                })
            },
            targetProvider: { _ in
                DictationTarget(processID: 1, bundleID: "app\(counter.next())")
            }
        )
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()

        #expect(await inserted.inserted == ["a@app1", "b@app2"])
    }
}

private actor DefaultRecorder: DictationRecorder {
    private(set) var transcribed = 0
    func start() async throws {}
    func stopAndTranscribe() async throws -> String {
        transcribed += 1
        return "now"
    }
}

extension DictationBackToBackTests {
    @Test("a quick tap inside an Escape cancel captures nothing and leaves the mic closed", .timeLimit(.minutes(1)))
    func tapDuringCancel() async {
        let hold = HoldOnce()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: ScriptedInserter(), features: .all
        ) { state in if state == .idle { await hold.hold() } }
        await coord.handle(.press)
        let cancelling = Task { await coord.cancelListening() }
        await hold.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)
        await hold.open()
        await cancelling.value
        await coord.drain()

        #expect(await coord.state == .idle)
        #expect(await recorder.realStarts == 1)
    }

    @Test("a push-to-talk hold released inside a Stop finish still takes its words", .timeLimit(.minutes(1)))
    func pushToTalkPressAfterTheEndStarts() async {
        let hold = HoldOnce()
        let store = ScriptedInserter()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: store, features: .all
        ) { state in if state == .transcribing { await hold.hold() } }
        await coord.handle(.press)
        let stopping = Task { await coord.stopListening() }
        await hold.waitEntered()
        await coord.handle(.press)
        await hold.open()
        await stopping.value
        await coord.handle(.release)
        await coord.drain()

        #expect(await recorder.realStarts == 2)
        #expect(await store.inserted == ["take1", "take2"])
    }

    @Test("toggle: a start and a stop pressed inside a Stop finish cancel each other", .timeLimit(.minutes(1)))
    func togglePairDuringFinish() async {
        let hold = HoldOnce()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: ScriptedInserter(), mode: .toggle, features: .all
        ) { state in if state == .transcribing { await hold.hold() } }
        await coord.handle(.press)
        let stopping = Task { await coord.stopListening() }
        await hold.waitEntered()
        await coord.handle(.press)
        await coord.handle(.press)
        await hold.open()
        await stopping.value
        await coord.drain()

        #expect(await coord.state == .idle)
        #expect(await recorder.realStarts == 1)
    }

    @Test("hybrid: a hold released inside the end cancels its pending start", .timeLimit(.minutes(1)))
    func hybridHoldDuringEnd() async {
        let hold = HoldOnce()
        let recorder = SingleSlotRecorder()
        let coord = DictationCoordinator(
            hotkey: QuietHotkey(), recorder: recorder, inserter: ScriptedInserter(), mode: .hybrid, features: .all
        ) { state in if state == .idle { await hold.hold() } }
        let down = Date()
        await coord.handle(.press, capturedAt: down)
        let cancelling = Task { await coord.cancelListening() }
        await hold.waitEntered()
        await coord.handle(.press, capturedAt: down.addingTimeInterval(1))
        await coord.handle(.release, capturedAt: down.addingTimeInterval(1.6))
        await hold.open()
        await cancelling.value

        #expect(await coord.state == .idle)
        #expect(await recorder.realStarts == 1)
    }

    @Test("stopping without waiting returns behind a stuck take, so the next coordinator isn't held up", .timeLimit(.minutes(1)))
    func stopDoesNotWaitForStuckTakes() async {
        let stuck = Gate()
        let recorder = ScriptedRecorder([.init(text: "one", finalizeGate: stuck), .init(text: "two", finalizeGate: stuck)])
        let coord = makeCoordinator(recorder: recorder, inserter: ScriptedInserter())
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await stuck.waitEntered()
        await coord.handle(.press)
        await coord.handle(.release)

        await coord.stopMonitoring(waitingForTakes: false)

        #expect(await coord.state == .transcribing)
        await stuck.open()
        await coord.drain()
    }

    @Test("giving up on the take being processed keeps an earlier failure nobody has seen", .timeLimit(.minutes(1)))
    func abandonKeepsAnUnseenFailure() async {
        let tail = Gate()
        let recorder = ScriptedRecorder([.init(text: "", failure: "boom"), .init(text: "two", finalizeGate: tail)])
        let coord = makeCoordinator(recorder: recorder, inserter: ScriptedInserter())
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await coord.handle(.release)
        await tail.waitEntered()

        #expect(await coord.abandonTranscription())

        #expect(await coord.state == .failed("boom"))
        await tail.open()
    }

    @Test("a take dropped during its cleanup is never inserted", .timeLimit(.minutes(1)))
    func abandonDuringCleanup() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([.init(text: "one")])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup))
        await coord.handle(.press)
        await coord.handle(.release)
        await cleanup.waitEntered()

        #expect(await coord.abandonTranscription())
        await cleanup.open()
        await coord.drain()

        #expect(await inserter.inserted.isEmpty)
    }

    @Test("a press keeps a failure nobody has seen while another take is processed", .timeLimit(.minutes(1)))
    func pressKeepsAnUnseenFailure() async {
        let cleanup = Gate()
        let recorder = ScriptedRecorder([
            .init(text: "", failure: "boom"), .init(text: "two"), .init(text: "three"),
        ])
        let inserter = ScriptedInserter()
        let coord = makeCoordinator(recorder: recorder, inserter: inserter, processor: GatedProcessor(gate: cleanup))
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.handle(.press)
        await coord.handle(.release)
        await cleanup.waitEntered()
        #expect(await coord.state == .transcribing)

        await coord.handle(.press)
        await cleanup.open()
        await coord.handle(.release)
        await coord.drain()

        #expect(await inserter.inserted == ["two", "three"])
        #expect(await coord.state == .failed("boom"))
    }

    @Test("a recorder without its own stopCapture transcribes before the release returns, so the next start can't race it")
    func defaultStopCaptureIsEager() async throws {
        let recorder = DefaultRecorder()

        let take = try await recorder.stopCapture()

        #expect(await recorder.transcribed == 1)
        #expect(try await take.finalize() == "now")
        #expect(await recorder.transcribed == 1)
    }
}

private final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int {
        value.withLock {
            $0 += 1
            return $0
        }
    }
}
