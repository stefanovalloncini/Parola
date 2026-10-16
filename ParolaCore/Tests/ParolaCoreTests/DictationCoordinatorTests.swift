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
        var discardCalls = 0
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

        func stopAndDiscard() async {
            discardCalls += 1
        }
    }

    private actor MockInserter: TextInserter {
        var inserted: [String] = []
        func insert(_ text: String) async {
            inserted.append(text)
        }
    }

    private struct BlockedInserter: TextInserter {
        struct Blocked: LocalizedError {
            var errorDescription: String? { "insert blocked" }
        }
        func insert(_ text: String) async throws {
            throw Blocked()
        }
    }

    @Test("a throwing inserter surfaces as the failed state")
    func insertFailureBecomesFailedState() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("hello"))
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: BlockedInserter())
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        await #expect(coord.state == .failed("insert blocked"))
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
        await coord.drain()
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
        await coord.drain()
        let stops = await recorder.stopCalls
        #expect(stops == 0)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    private actor StateRecorder {
        var captured: [DictationCoordinator.State] = []
        func record(_ s: DictationCoordinator.State) { captured.append(s) }
    }

    private actor SpyMuter: SystemAudioMuter {
        private(set) var current = false
        func isMuted() async -> Bool { current }
        func setMuted(_ muted: Bool) async { current = muted }
    }

    private actor SpyPlayer: MediaPlaybackToggler {
        private(set) var pauseCalls = 0
        private(set) var playCalls = 0
        func pause() async { pauseCalls += 1 }
        func play() async { playCalls += 1 }
    }

    @Test("media session enters on listening and exits when the utterance finishes")
    func mediaSessionAroundListening() async throws {
        let muter = SpyMuter()
        let player = SpyPlayer()
        let media = MediaSession(muter: muter, player: player)
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: MockRecorder(outcome: .text("hi")),
            inserter: MockInserter(),
            mediaSession: media,
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: true) }
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        let mutedWhileListening = await muter.current
        let pausesAfterPress = await player.pauseCalls
        #expect(mutedWhileListening)
        #expect(pausesAfterPress == 1)

        await coord.handle(.release)
        await coord.drain()
        let mutedAfterRelease = await muter.current
        let playsAfterRelease = await player.playCalls
        #expect(mutedAfterRelease == false)
        #expect(playsAfterRelease == 1)
    }

    @Test("abort while listening exits the media session")
    func abortExitsMediaSession() async throws {
        let muter = SpyMuter()
        let player = SpyPlayer()
        let media = MediaSession(muter: muter, player: player)
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: MockRecorder(outcome: .text("hi")),
            inserter: MockInserter(),
            mediaSession: media,
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: true) }
        )
        await coord.startMonitoring()
        await coord.handle(.press)

        await coord.abortMonitoring()
        let muted = await muter.current
        let plays = await player.playCalls
        #expect(muted == false)
        #expect(plays == 1)
    }

    @Test("transcriber failure rests in an observable failed state")
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
        await coord.drain()
        await #expect(coord.state == .failed("mic error"))
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
        let captured = await stateRecorder.captured
        #expect(captured.contains(where: {
            if case .failed = $0 { return true } else { return false }
        }))
    }

    @Test("a press after a failure recovers and starts listening again")
    func recoversFromFailedState() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .failure("mic error"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        await #expect(coord.state == .failed("mic error"))

        await coord.handle(.press)
        await #expect(coord.state == .listening)
        let starts = await recorder.startCalls
        #expect(starts == 2)
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
        await coord.drain()
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
        await coord.drain()
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
        await coord.drain()
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
        await coord.drain()
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        await coord.drain()
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
        await coord.drain()
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
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
        await coord.drain()
        await #expect(coord.state == .listening)
        await coord.handle(.press)
        try await Task.sleep(for: .milliseconds(350))
        await #expect(coord.state == .listening)
        await coord.handle(.release)
        await coord.drain()
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["held"])
    }

    @Test("hybrid mode: an intent press during a physical hold leaves the release a release")
    func hybridIntentPressDuringHold() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("still held"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            mode: .hybrid
        )
        await coord.startMonitoring()
        let keyDown = Date()
        await coord.handle(.press, capturedAt: keyDown)
        await #expect(coord.state == .listening)

        await coord.handle(.press, capturedAt: keyDown.addingTimeInterval(0.4))
        await coord.handle(.release, capturedAt: keyDown.addingTimeInterval(0.5))
        await coord.drain()

        await #expect(coord.state == .idle)
        let startCalls = await recorder.startCalls
        #expect(startCalls == 1)
        let inserted = await inserter.inserted
        #expect(inserted == ["still held"])
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
        await coord.drain()
        await coord.setMode(.pushToTalk)
        await coord.handle(.release)
        await coord.drain()
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
        await coord.drain()
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
        private let text: String

        init(text: String = "") { self.text = text }

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
            return text
        }

        func stopAndDiscard() async {
            discardCalls += 1
            running = false
        }

        private(set) var discardCalls = 0
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
        await coord.drain()

        await #expect(coord.state == .idle)
        let running = await recorder.running
        #expect(running == false, "recorder must be stopped, not orphaned, after abort races startup")
    }

    @Test("aborting mid-startup discards at once, without waiting for the recorder to come up")
    func abortDuringStartupDiscardsAtOnce() async throws {
        let recorder = GatedRecorder()
        let coord = DictationCoordinator(hotkey: MockHotkey(), recorder: recorder, inserter: MockInserter())
        await coord.startMonitoring()
        let press = Task { await coord.simulatePress() }
        var spins = 0
        while await recorder.gateArmed == false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        await coord.abortMonitoring()

        #expect(await recorder.discardCalls == 1)
        await recorder.openGate()
        await press.value
        await coord.drain()
        #expect(await recorder.discardCalls == 2, "the start that returned late discards again")
    }

    private actor CancellableRecorder: DictationRecorder {
        private var parked: CheckedContinuation<Void, Never>?
        private(set) var isParked = false
        private(set) var discardCalls = 0

        func start() async throws {
            await withCheckedContinuation { parked = $0; isParked = true }
            throw CancellationError()
        }

        func stopAndTranscribe() async throws -> String { "" }

        func stopAndDiscard() async {
            discardCalls += 1
            parked?.resume()
            parked = nil
        }
    }

    @Test("aborting mid-startup of a recorder that cancels leaves the media session and rests idle, never failed", .timeLimit(.minutes(1)))
    func abortDuringCancellableStartupExitsMedia() async throws {
        let muter = SpyMuter()
        let player = SpyPlayer()
        let recorder = CancellableRecorder()
        let states = StateRecorder()
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: recorder,
            inserter: MockInserter(),
            mediaSession: MediaSession(muter: muter, player: player),
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: true) }
        ) { await states.record($0) }
        await coord.startMonitoring()
        let press = Task { await coord.simulatePress() }
        var spins = 0
        while await recorder.isParked == false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        await coord.abortMonitoring()
        await press.value
        await coord.drain()

        #expect(await muter.current == false)
        #expect(await player.playCalls == 1)
        #expect(await coord.state == .idle)
        let seen = await states.captured
        #expect(!seen.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("a release that races recorder startup is deferred, then transcribes once it is up")
    func releaseDuringStartupIsDeferredNotDropped() async throws {
        let hotkey = MockHotkey()
        let recorder = GatedRecorder(text: "deferred")
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

        // Release arrives while the recorder is still starting: `.listening` must not be reported
        // yet, and nothing is inserted until the recorder is actually up.
        await coord.simulateRelease()
        await coord.drain()
        await #expect(coord.state != .listening)
        let insertedDuringStart = await inserter.inserted
        #expect(insertedDuringStart.isEmpty)

        await recorder.openGate()
        await press.value
        await coord.drain()

        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["deferred"], "the deferred release must transcribe-and-insert once the recorder finishes starting")
    }

    @Test("abortMonitoring discards the recording without transcribing")
    func abortDiscardsWithoutTranscribing() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("discard me"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)

        await coord.abortMonitoring()

        await #expect(coord.state == .idle)
        let discards = await recorder.discardCalls
        let stops = await recorder.stopCalls
        #expect(discards == 1, "abort must release the mic via the discard path")
        #expect(stops == 0, "abort must not run a transcription of audio it is throwing away")
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    @Test("a start that loses its generation discards, not transcribes")
    func rolledBackStartDiscards() async throws {
        let hotkey = MockHotkey()
        let recorder = GatedRecorder(text: "rolled back")
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
        await coord.drain()

        let discards = await recorder.discardCalls
        let stops = await recorder.stopCalls
        #expect(discards == 2, "the rolled-back start must release the mic via the discard path")
        #expect(stops == 0, "the rolled-back start must not transcribe audio nobody wants")
    }

    @Test("events after teardown never start the recorder")
    func eventsAfterTeardownIgnored() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("orphan"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter)
        await coord.startMonitoring()
        await coord.stopMonitoring()
        await coord.handle(.press)
        let starts = await recorder.startCalls
        #expect(starts == 0, "a press landing after teardown must not revive the mic")
        await #expect(coord.state == .idle)
    }

    @Test("toggle mode: an explicit stop request finishes the session")
    func stopRequestFinishesToggleSession() async throws {
        let hotkey = MockHotkey()
        let recorder = MockRecorder(outcome: .text("toggled off"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter, mode: .toggle)
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        await #expect(coord.state == .listening)
        await coord.stopListening()
        await coord.drain()
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["toggled off"])
    }

    private actor StuckFinishRecorder: DictationRecorder {
        private(set) var finishing = false
        private var gate: CheckedContinuation<Void, Never>?

        func start() async throws {}

        func stopAndTranscribe() async throws -> String {
            finishing = true
            await withCheckedContinuation { gate = $0 }
            return "late text"
        }

        func stopAndDiscard() async {}

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    @Test("giving up on a stuck final transcription goes idle and never inserts its late text")
    func abandonedTranscriptionDropsLateText() async throws {
        let recorder = StuckFinishRecorder()
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: MockHotkey(), recorder: recorder, inserter: inserter, mode: .toggle)
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)

        let finishing = Task { await coord.stopListening() }
        var spins = 0
        while await recorder.finishing == false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        await #expect(coord.state == .transcribing)

        await coord.abandonTranscription()
        await #expect(coord.state == .idle)

        await recorder.release()
        await finishing.value
        await coord.drain()
        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted.isEmpty)
    }

    private actor QueuedFinishRecorder: DictationRecorder {
        private var texts: [String]
        private var gates: [CheckedContinuation<Void, Never>] = []

        init(texts: [String]) { self.texts = texts }

        var waiting: Int { gates.count }

        func start() async throws {}

        func stopAndTranscribe() async throws -> String {
            let text = texts.removeFirst()
            await withCheckedContinuation { gates.append($0) }
            return text
        }

        func stopAndDiscard() async {}

        func releaseNext() {
            guard !gates.isEmpty else { return }
            gates.removeFirst().resume()
        }
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    @Test("a stop's give-up belongs to its own final: the next session still finishes and inserts")
    func giveUpLeavesTheNextSessionAlone() async throws {
        let recorder = QueuedFinishRecorder(texts: ["one", "two"])
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: MockHotkey(), recorder: recorder, inserter: inserter, mode: .toggle)
        await coord.startMonitoring()

        await coord.handle(.press)
        let first = Task { await coord.stopListening() }
        let recorderIsWaitingOnce = await eventually { await recorder.waiting == 1 }
        #expect(recorderIsWaitingOnce)
        let giveUp = Task { await coord.giveUpOnTranscription(after: .milliseconds(300)) }

        await recorder.releaseNext()
        await first.value
        await coord.drain()
        #expect(await inserter.inserted == ["one"])

        await coord.handle(.press)
        let second = Task { await coord.stopListening() }
        let recorderIsWaitingOnceAgain = await eventually { await recorder.waiting == 1 }
        #expect(recorderIsWaitingOnceAgain)
        #expect(await giveUp.value == false, "the timer fires while the second final runs and must leave it alone")
        await #expect(coord.state == .transcribing)

        await recorder.releaseNext()
        await second.value
        await coord.drain()
        #expect(await inserter.inserted == ["one", "two"])
        await #expect(coord.state == .idle)
    }

    @Test("a give-up on a final that never lands ends the session and drops its text")
    func giveUpEndsAStuckFinal() async throws {
        let recorder = QueuedFinishRecorder(texts: ["late"])
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: MockHotkey(), recorder: recorder, inserter: inserter, mode: .toggle)
        await coord.startMonitoring()
        await coord.handle(.press)
        let finish = Task { await coord.stopListening() }
        let recorderIsWaitingOnce = await eventually { await recorder.waiting == 1 }
        #expect(recorderIsWaitingOnce)

        #expect(await coord.giveUpOnTranscription(after: .milliseconds(20)))
        await #expect(coord.state == .idle)

        await recorder.releaseNext()
        await finish.value
        #expect(await inserter.inserted.isEmpty)
    }

    @Test("a stop in the failed state rests the session idle")
    func stopInFailedStateGoesIdle() async throws {
        let coord = DictationCoordinator(
            hotkey: MockHotkey(), recorder: MockRecorder(outcome: .failure("boom")), inserter: MockInserter()
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await coord.handle(.release)
        await coord.drain()
        guard case .failed = await coord.state else {
            Issue.record("expected the failed state")
            return
        }

        await coord.stopListening()
        await coord.drain()

        await #expect(coord.state == .idle)
    }

    @Test("a stop request during recorder startup is deferred, then finishes")
    func stopRequestDuringStartupIsDeferred() async throws {
        let hotkey = MockHotkey()
        let recorder = GatedRecorder(text: "deferred stop")
        let inserter = MockInserter()
        let coord = DictationCoordinator(hotkey: hotkey, recorder: recorder, inserter: inserter, mode: .toggle)
        await coord.startMonitoring()

        let press = Task { await coord.simulatePress() }
        var spins = 0
        while await recorder.gateArmed == false {
            await Task.yield()
            spins += 1
            if spins > 100_000 { break }
        }

        await coord.stopListening()
        await coord.drain()
        await #expect(coord.state != .listening)
        let insertedDuringStart = await inserter.inserted
        #expect(insertedDuringStart.isEmpty)

        await recorder.openGate()
        await press.value
        await coord.drain()

        await #expect(coord.state == .idle)
        let inserted = await inserter.inserted
        #expect(inserted == ["deferred stop"], "a stop requested mid-startup must finish the session once the recorder is up")
    }

    private actor CallOrderRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private actor LoggingMuter: SystemAudioMuter {
        private let log: CallOrderRecorder
        private var current = false
        init(log: CallOrderRecorder) { self.log = log }
        func isMuted() async -> Bool {
            await log.record("mediaSession.enterRecording")
            return current
        }
        func setMuted(_ muted: Bool) async { current = muted }
    }

    private actor InertPlayer: MediaPlaybackToggler {
        func pause() async {}
        func play() async {}
    }

    private actor LoggingRecorder: DictationRecorder {
        private let log: CallOrderRecorder
        init(log: CallOrderRecorder) { self.log = log }
        func start() async throws { await log.record("recorder.start") }
        func stopAndTranscribe() async throws -> String { "done" }
        func stopAndDiscard() async {}
    }

    @Test("willListen runs before mediaSession.enterRecording and before recorder.start()")
    func willListenRunsBeforeSessionAndRecorder() async throws {
        let log = CallOrderRecorder()
        let media = MediaSession(muter: LoggingMuter(log: log), player: InertPlayer())
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: LoggingRecorder(log: log),
            inserter: MockInserter(),
            mediaSession: media,
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: false) },
            willListen: { await log.record("willListen") }
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)
        let events = await log.events
        #expect(events == ["willListen", "mediaSession.enterRecording", "recorder.start"])
    }

    @Test("a nil willListen hook leaves today's start order unchanged")
    func nilWillListenLeavesOrderUnchanged() async throws {
        let log = CallOrderRecorder()
        let media = MediaSession(muter: LoggingMuter(log: log), player: InertPlayer())
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: LoggingRecorder(log: log),
            inserter: MockInserter(),
            mediaSession: media,
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: false) }
        )
        await coord.startMonitoring()
        await coord.handle(.press)
        await #expect(coord.state == .listening)
        let events = await log.events
        #expect(events == ["mediaSession.enterRecording", "recorder.start"])
    }

    /// Both `isOpen` and `hasEntered` latch, so a call that arrives after the matching signal already fired returns at once instead of parking forever.
    private actor Gate {
        private var isOpen = false
        private var hasEntered = false
        private var openContinuation: CheckedContinuation<Void, Never>?
        private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            hasEntered = true
            for continuation in enteredContinuations { continuation.resume() }
            enteredContinuations = []
            if isOpen { return }
            await withCheckedContinuation { openContinuation = $0 }
        }

        func open() {
            isOpen = true
            openContinuation?.resume()
            openContinuation = nil
        }

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { enteredContinuations.append($0) }
        }
    }

    @Test("a willListen hook that awaits a gate holds recorder.start() until released")
    func willListenGateHoldsRecorderStart() async throws {
        let gate = Gate()
        let recorder = MockRecorder(outcome: .text("hi"))
        let inserter = MockInserter()
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: recorder,
            inserter: inserter,
            willListen: { await gate.wait() }
        )
        await coord.startMonitoring()

        let press = Task { await coord.simulatePress() }
        let entered: Void? = await AsyncTimeout.run(.seconds(2)) { await gate.waitUntilEntered() }
        #expect(entered != nil, "the willListen hook never started")

        let startsBeforeOpen = await recorder.startCalls
        #expect(startsBeforeOpen == 0, "recorder.start() must not run while the willListen hook is still awaiting")

        await gate.open()
        let finished: Void? = await AsyncTimeout.run(.seconds(2)) { await press.value }
        #expect(finished != nil, "beginListening never returned after the gate opened")

        await #expect(coord.state == .listening)
        let startsAfterOpen = await recorder.startCalls
        #expect(startsAfterOpen == 1)
    }

    @Test("a teardown during the willListen hook rolls back before muting or starting the recorder")
    func teardownDuringWillListenRollsBackFirst() async throws {
        let gate = Gate()
        let muter = SpyMuter()
        let player = SpyPlayer()
        let media = MediaSession(muter: muter, player: player)
        let recorder = MockRecorder(outcome: .text("hi"))
        let coord = DictationCoordinator(
            hotkey: MockHotkey(),
            recorder: recorder,
            inserter: MockInserter(),
            mediaSession: media,
            mediaConfigProvider: { MediaSessionConfig(muteSystemAudio: true, pausePlayback: true) },
            willListen: { await gate.wait() }
        )
        await coord.startMonitoring()

        let press = Task { await coord.simulatePress() }
        let entered: Void? = await AsyncTimeout.run(.seconds(2)) { await gate.waitUntilEntered() }
        #expect(entered != nil, "the willListen hook never started")

        await coord.abortMonitoring()
        await gate.open()
        let finished: Void? = await AsyncTimeout.run(.seconds(2)) { await press.value }
        #expect(finished != nil, "beginListening never returned after the gate opened")

        await #expect(coord.state == .idle)
        let muted = await muter.current
        let starts = await recorder.startCalls
        #expect(muted == false, "a teardown during the hook must never mute system audio")
        #expect(starts == 0, "a teardown during the hook must never open the mic")
    }
}
