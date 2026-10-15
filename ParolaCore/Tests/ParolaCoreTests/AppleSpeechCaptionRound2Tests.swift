import Foundation
import Testing
import os
@testable import ParolaCore

private final class Analyzer: CaptionAnalyzing {
    let recognitions: AsyncThrowingStream<CaptionRecognition, any Error>
    let output: AsyncThrowingStream<CaptionRecognition, any Error>.Continuation
    let finalizeGate = UninterruptibleGate()
    let finalizeCalls = Awaitable(0)
    let cancelled = TestSignal()
    let parksFinalize: Bool
    let heldFinal: String?

    init(parksFinalize: Bool = false, heldFinal: String? = nil) {
        (recognitions, output) = AsyncThrowingStream<CaptionRecognition, any Error>.makeStream()
        self.parksFinalize = parksFinalize
        self.heldFinal = heldFinal
    }

    func say(_ text: String) {
        output.yield(CaptionRecognition(text: text, start: 0, end: 1, isFinal: false))
    }

    func feed(_ samples: [Float]) {}

    func finalize() async throws {
        finalizeCalls.increment()
        if parksFinalize { await finalizeGate.wait() }
        if let heldFinal { output.yield(CaptionRecognition(text: heldFinal, start: 0, end: 1, isFinal: true)) }
        output.finish()
    }

    func cancel() async {
        cancelled.fire()
        output.finish()
    }
}

private final class Capture: Sendable {
    let startGate = UninterruptibleGate()
    let stopped = Awaitable(0)
    let parksStart: Bool
    private let ended = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    init(parksStart: Bool) { self.parksStart = parksStart }

    var capture: CaptionCapture {
        CaptionCapture(
            requestPermission: { true }, deniedText: "denied",
            start: { [self] _ in if parksStart { await startGate.wait() } },
            stop: { [self] in stopped.increment() },
            interruptStart: nil,
            whenEnded: { [self] handler in ended.withLock { $0 = handler } }
        )
    }

    func end(_ text: String) { ended.withLock { $0 }?(text) }
}

private func collect(_ stream: AsyncStream<StreamingEvent>) -> Awaitable<[String]> {
    let seen = Awaitable<[String]>([])
    Task {
        for await event in stream {
            let text: String = switch event {
            case .partial(let t): "partial:\(t)"
            case .confirmed(let s): "confirmed:\(s.text)"
            case .failed(let t): "failed:\(t)"
            case .finished: "finished"
            default: "other"
            }
            seen.update { $0.append(text) }
        }
        seen.update { $0.append("<end>") }
    }
    return seen
}

private func session(
    _ analyzer: Analyzer, _ capture: Capture, gate: SettleGate = SettleGate(duration: .milliseconds(1)),
    creation: UninterruptibleGate? = nil, creationThrows: Bool = false
) -> AppleSpeechCaptionSession {
    AppleSpeechCaptionSession(
        source: .systemAudio,
        backend: AppleSpeechCaptionBackend(
            prepare: { locale, _ in locale },
            makeAnalyzer: { _ in
                if let creation { await creation.wait() }
                if creationThrows { throw CancellationError() }
                return analyzer
            }
        ),
        capture: { _ in capture.capture },
        settleGate: gate
    )
}

private let opts = TranscriptionOptions(model: "apple-speech-analyzer", language: "en")

private func within(_ what: String, seconds: Int = 10, _ work: @escaping @Sendable () async -> Void) async throws {
    _ = try await GuardedTask { await work() }.value(what, timeout: .seconds(seconds))
}

@Suite("Apple Speech caption lifecycle, round 2", .timeLimit(.minutes(1)))
struct AppleSpeechCaptionRound2Tests {
    @Test("a failure while a capture with no interruptStart is starting still stops that capture, once")
    func failDuringStartStopsCapture() async throws {
        let analyzer = Analyzer()
        let capture = Capture(parksStart: true)
        let live = session(analyzer, capture)
        let events = collect(try await live.start(options: opts))
        await capture.startGate.arrivals.wait(atLeast: 1, "the capture start to park")
        analyzer.output.finish(throwing: CaptionCaptureError(text: "analyzer crashed"))
        await events.wait(until: { $0.last == "<end>" }, "the stream to end")
        capture.startGate.open()
        await capture.stopped.wait(atLeast: 1, "the capture to be stopped")
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.stopped.value == 1)
    }

    @Test("a capture end whose hop lands during the stop's finalize adds nothing")
    func endDuringStopFinalize() async throws {
        let analyzer = Analyzer(parksFinalize: true)
        let capture = Capture(parksStart: false)
        let live = session(analyzer, capture)
        let events = collect(try await live.start(options: opts))
        analyzer.say("held")
        await events.wait(until: { $0.contains("partial:held") }, "partial")
        let stopping = GuardedTask { await live.stop() }
        await analyzer.finalizeCalls.wait(atLeast: 1, "finalize")
        capture.end(FixedFailureText.systemAudioStopped)
        try await Task.sleep(for: .milliseconds(200))
        analyzer.finalizeGate.open()
        _ = try await stopping.value("stop", timeout: .seconds(10))
        await events.wait(until: { $0.last == "<end>" }, "end")
        #expect(events.value == ["partial:held", "finished", "<end>"], "\(events.value)")
        #expect(analyzer.finalizeCalls.value == 1)
    }

    @Test("a cancel that lands while stop waits for a starting capture starts no finalize")
    func cancelBeforeSettleSkipsFinalize() async throws {
        let analyzer = Analyzer(heldFinal: "held")
        let capture = Capture(parksStart: true)
        let live = session(analyzer, capture)
        let events = collect(try await live.start(options: opts))
        await capture.startGate.arrivals.wait(atLeast: 1, "the capture start to park")
        let stopping = GuardedTask { await live.stop() }
        try await Task.sleep(for: .milliseconds(100))
        try await within("the cancel") { await live.cancel() }
        capture.startGate.open()
        _ = try await stopping.value("stop", timeout: .seconds(10))
        await events.wait(until: { $0.last == "<end>" }, "end")
        #expect(analyzer.finalizeCalls.value == 0, "\(events.value)")
    }

    @Test("a stop during creation that then throws releases the gate at once")
    func creationThrowReleasesGate() async throws {
        let analyzer = Analyzer()
        let creation = UninterruptibleGate()
        let gate = SettleGate(duration: .milliseconds(20))
        let live = session(analyzer, Capture(parksStart: false), gate: gate, creation: creation, creationThrows: true)
        let events = collect(try await live.start(options: opts))
        await creation.arrivals.wait(atLeast: 1, "creation to park")
        try await within("the stop") { await live.stop() }
        await events.wait(until: { $0.last == "<end>" }, "end")
        creation.open()
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        await gate.waitUntilSettled()
        #expect(ContinuousClock.now - began < .milliseconds(500))
    }

    @Test("a stop during creation releases the gate right after the late cancel")
    func lateCancelReleasesGate() async throws {
        let analyzer = Analyzer()
        let creation = UninterruptibleGate()
        let gate = SettleGate(duration: .milliseconds(20))
        let live = session(analyzer, Capture(parksStart: false), gate: gate, creation: creation)
        let events = collect(try await live.start(options: opts))
        await creation.arrivals.wait(atLeast: 1, "creation to park")
        try await within("the stop") { await live.stop() }
        await events.wait(until: { $0.last == "<end>" }, "end")
        creation.open()
        await analyzer.cancelled.wait("the late cancel")
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        await gate.waitUntilSettled()
        #expect(ContinuousClock.now - began < .milliseconds(500))
    }
}

@Suite("Apple Speech asset install, round 2", .timeLimit(.minutes(1)))
struct AssetInstallRound2Tests {
    private final class Request: AssetInstalling {
        private let fraction = OSAllocatedUnfairLock(initialState: 0.0)
        private let outcome = FirstResult<Result<Void, any Error>>()
        let honoursCancel: Bool
        let cancelled = TestSignal()
        let gate = UninterruptibleGate()

        init(honoursCancel: Bool = true) { self.honoursCancel = honoursCancel }

        var fractionCompleted: Double { fraction.withLock { $0 } }
        func move(to value: Double) { fraction.withLock { $0 = value } }
        func finish() { outcome.resolve(.success(())) }

        func downloadAndInstall() async throws {
            if !honoursCancel { await gate.wait(); return }
            try await outcome.wait().get()
        }

        func cancel() {
            cancelled.fire()
            if honoursCancel { outcome.resolve(.failure(CancellationError())) }
        }
    }

    private static let poll = Duration.seconds(1)

    private func start(_ request: Request, _ clock: TestClock) -> GuardedTask<Void> {
        GuardedTask {
            try await AssetInstall.run(
                request, locale: Locale(identifier: "it_IT"), stallLimit: .seconds(60), poll: Self.poll, clock: clock
            ) { _ in }
        }
    }

    private func tick(_ clock: TestClock, _ times: Int) async {
        for _ in 0..<times {
            await clock.waitForSleeper()
            clock.advance(by: Self.poll)
        }
    }

    @Test("progress that moves, stalls and moves again restarts the stall count")
    func stallCountResets() async throws {
        let request = Request()
        let clock = TestClock()
        let task = start(request, clock)
        request.move(to: 0.2)
        await tick(clock, 50)
        request.move(to: 0.3)
        await tick(clock, 50)
        #expect(!task.isFinished, "the count did not restart after the move")
        request.finish()
        _ = try await task.value("the install to return")
    }

    @Test("progress that sits at the end for a long time is not a stall")
    func installStepIsNotAStall() async throws {
        let request = Request()
        let clock = TestClock()
        let task = start(request, clock)
        request.move(to: 0.995)
        await tick(clock, 130)
        #expect(!task.isFinished)
        #expect(!request.cancelled.fired)
        request.finish()
        _ = try await task.value("the install to return")
    }

    @Test("a request that ignores cancel still lets a cancelled install return")
    func deafRequestStillStops() async throws {
        let request = Request(honoursCancel: false)
        let task = GuardedTask {
            try await AssetInstall.run(request, locale: Locale(identifier: "it_IT"), clock: ContinuousClock()) { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value("the install to end", timeout: .seconds(5)) }
        request.gate.open()
    }
}

@Suite("Caption sentence timing, round 2", .timeLimit(.minutes(1)))
struct CaptionSentenceRound2Tests {
    @Test("runs shaped like Speech's, with the space before each word, give sentence times that don't overlap")
    func speechShapedRuns() {
        let runs: [CaptionRecognition.Run] = [
            .init(text: "Buongiorno", start: 0.0, end: 0.5),
            .init(text: " a", start: 0.5, end: 0.6),
            .init(text: " tutti.", start: 0.6, end: 1.0),
            .init(text: " Grazie", start: 1.4, end: 1.8),
            .init(text: " mille.", start: 1.8, end: 2.2),
        ]
        let text = runs.map(\.text).joined()
        let pieces = CaptionSentences.split(CaptionRecognition(text: text, start: 0, end: 2.2, isFinal: true, runs: runs))
        #expect(pieces.map(\.text) == ["Buongiorno a tutti.", "Grazie mille."])
        #expect(pieces.map(\.end) == [1.0, 2.2])
        #expect(pieces.map(\.start) == [0.0, 1.4])
    }

    @Test("the language name has no region, also for a region-override locale")
    func languageNameIsTheLanguage() {
        let italian = LiveSpeechCaption.languageName(Locale(identifier: "it_IT"))
        #expect(italian == Locale.current.localizedString(forLanguageCode: "it"))
        let override = LiveSpeechCaption.languageName(Locale(identifier: "en_US@rg=itzzzz"))
        #expect(override == Locale.current.localizedString(forLanguageCode: "en"))
    }
}
