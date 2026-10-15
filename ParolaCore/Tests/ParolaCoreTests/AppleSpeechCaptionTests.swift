import AVFoundation
import Foundation
import Testing
import os
@testable import ParolaCore

private final class FakeAnalyzer: CaptionAnalyzing {
    let recognitions: AsyncThrowingStream<CaptionRecognition, any Error>
    let output: AsyncThrowingStream<CaptionRecognition, any Error>.Continuation
    private let held: OSAllocatedUnfairLock<[CaptionRecognition]>
    let fed = Awaitable(0)
    let finalized = TestSignal()
    let cancelled = TestSignal()
    let failsToFinalize: Bool
    let parksFinalize: Bool
    let finalizeGate = UninterruptibleGate()
    let finalizeStarted = TestSignal()

    init(holding held: [CaptionRecognition] = [], failsToFinalize: Bool = false, parksFinalize: Bool = false) {
        (recognitions, output) = AsyncThrowingStream<CaptionRecognition, any Error>.makeStream()
        self.held = OSAllocatedUnfairLock(initialState: held)
        self.failsToFinalize = failsToFinalize
        self.parksFinalize = parksFinalize
    }

    func endResults() { output.finish() }

    func say(_ text: String, _ start: Double = 0, _ end: Double = 1, final: Bool = false) {
        output.yield(CaptionRecognition(text: text, start: start, end: end, isFinal: final))
    }

    func crash() {
        output.finish(throwing: CaptionCaptureError(text: "analyzer crashed"))
    }

    func feed(_ samples: [Float]) { fed.increment() }

    func finalize() async throws {
        finalized.fire()
        finalizeStarted.fire()
        if parksFinalize { await finalizeGate.wait() }
        if failsToFinalize { throw CaptionCaptureError(text: "no finalize") }
        for recognition in held.withLock({ $0 }) { output.yield(recognition) }
        output.finish()
    }

    func cancel() async {
        cancelled.fire()
        output.finish()
    }
}

private final class FakeBackend: Sendable {
    private struct State {
        var prepared: [Locale] = []
        var analyzers: [FakeAnalyzer] = []
        var unsupported: Set<String> = []
        var installFails = false
        var parksPrepare = false
        var creationError: (any Error)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let analyzerRequested = TestSignal()
    private let analyzerToMake: FakeAnalyzer

    let creationGate: UninterruptibleGate?

    init(analyzer: FakeAnalyzer = FakeAnalyzer(), parksCreation: Bool = false) {
        analyzerToMake = analyzer
        creationGate = parksCreation ? UninterruptibleGate() : nil
    }

    var prepared: [Locale] { state.withLock { $0.prepared } }
    var analyzer: FakeAnalyzer { analyzerToMake }
    var analyzersMade: Int { state.withLock { $0.analyzers.count } }

    func rejecting(_ identifier: String) -> Self {
        state.withLock { _ = $0.unsupported.insert(identifier) }
        return self
    }

    func failingCreation(with error: any Error) -> Self {
        state.withLock { $0.creationError = error }
        return self
    }

    func parkingPrepare() -> Self {
        state.withLock { $0.parksPrepare = true }
        return self
    }

    let preparing = TestSignal()

    func failingInstall() -> Self {
        state.withLock { $0.installFails = true }
        return self
    }

    var backend: AppleSpeechCaptionBackend {
        AppleSpeechCaptionBackend(
            prepare: { [self] locale, progress in
                state.withLock { $0.prepared.append(locale) }
                if state.withLock({ $0.unsupported.contains(locale.identifier) }) {
                    throw LiveSpeechCaption.noModel(for: locale)
                }
                if state.withLock({ $0.parksPrepare }) {
                    preparing.fire()
                    try await Task.sleep(for: .seconds(3600))
                }
                progress(0.5)
                if state.withLock({ $0.installFails }) { throw LiveSpeechCaption.downloadFailed(for: locale) }
                return locale
            },
            makeAnalyzer: { [self] _ in
                analyzerRequested.fire()
                if let creationGate { await creationGate.wait() }
                if let error = state.withLock({ $0.creationError }) { throw error }
                state.withLock { $0.analyzers.append(analyzerToMake) }
                return analyzerToMake
            }
        )
    }
}

private final class StandInCapture: Sendable {
    private struct State {
        var onBuffer: (@Sendable ([Float]) -> Void)?
        var onEnded: (@Sendable (String) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let granted: Bool
    let started = TestSignal()
    let stopped = TestSignal()
    let permissionGate: UninterruptibleGate?
    let startGate: UninterruptibleGate?

    init(granted: Bool = true, parksPermission: Bool = false, parksStart: Bool = false) {
        self.granted = granted
        permissionGate = parksPermission ? UninterruptibleGate() : nil
        startGate = parksStart ? UninterruptibleGate() : nil
    }

    var capture: CaptionCapture {
        CaptionCapture(
            requestPermission: { [self] in
                if let permissionGate { await permissionGate.wait() }
                return granted
            },
            deniedText: FixedFailureText.systemAudioNotAllowed,
            start: { [self] onBuffer in
                state.withLock { $0.onBuffer = onBuffer }
                if let startGate { await startGate.wait() }
                started.fire()
            },
            stop: { [self] in stopped.fire() },
            interruptStart: nil,
            whenEnded: { [self] handler in state.withLock { $0.onEnded = handler } }
        )
    }

    func push(seconds: Double = 0.1) {
        let onBuffer = state.withLock { $0.onBuffer }
        onBuffer?([Float](repeating: 0.1, count: Int(seconds * 16_000)))
    }

    func end(_ text: String) {
        state.withLock { $0.onEnded }?(text)
    }
}

private func session(
    _ fake: FakeBackend, _ capture: StandInCapture = StandInCapture(), gate: SettleGate = SettleGate(duration: .milliseconds(1)),
    settleLimit: Duration = .seconds(5)
) -> AppleSpeechCaptionSession {
    AppleSpeechCaptionSession(
        source: .systemAudio, backend: fake.backend, capture: { _ in capture.capture }, settleGate: gate,
        settleLimit: settleLimit
    )
}

private func startFailure(_ live: AppleSpeechCaptionSession, _ options: TranscriptionOptions) async -> String? {
    do {
        _ = try await live.start(options: options)
        return nil
    } catch let ParolaError.unsupportedForEngine(text) {
        return text
    } catch {
        return "other: \(error)"
    }
}

private func options(language: String? = "en", task: TranscriptionTask = .transcribe) -> TranscriptionOptions {
    TranscriptionOptions(model: AppleSpeechTranscriber.syntheticModelID, language: language, task: task)
}

private final class Events: Sendable {
    let all = Awaitable<[StreamingEvent]>([])

    func collect(_ stream: AsyncStream<StreamingEvent>) {
        Task { [all] in
            for await event in stream { all.update { $0.append(event) } }
            all.update { $0.append(.warning("<end>")) }
        }
    }

    static func ended(_ events: [StreamingEvent]) -> Bool {
        if case .warning("<end>")? = events.last { return true }
        return false
    }

    func texts() -> [String] {
        all.value.compactMap {
            switch $0 {
            case .partial(let text): "partial:\(text)"
            case .confirmed(let segment): "confirmed:\(segment.text)"
            case .failed(let text): "failed:\(text)"
            case .finished: "finished"
            default: nil
            }
        }
    }

    func wait(_ description: String, _ isMet: @escaping @Sendable ([StreamingEvent]) -> Bool) async {
        await all.wait(until: isMet, description)
    }
}

@Suite("Apple Speech captions", .timeLimit(.minutes(1)))
struct AppleSpeechCaptionTests {
    @Test("a volatile result is a partial and a final one a confirmed segment")
    func partialThenConfirm() async throws {
        let fake = FakeBackend()
        let capture = StandInCapture()
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        capture.push()
        await fake.analyzer.fed.wait(atLeast: 1, "the analyzer to be fed")

        fake.analyzer.say("hello wor")
        await events.wait("the partial") { $0.contains { if case .partial("hello wor") = $0 { true } else { false } } }
        fake.analyzer.say("hello world", 0, 1.2, final: true)
        await events.wait("the confirmed segment") { $0.contains { if case .confirmed = $0 { true } else { false } } }

        var state = LiveCaptionsState()
        for event in events.all.value { state.apply(event) }
        #expect(state.confirmedLines == ["hello world"])
        #expect(state.partial.isEmpty)
        await live.cancel()
    }

    @Test("stop settles the held words and finishes the take stamped as Apple Speech")
    func stopFinalisesHeldWords() async throws {
        let fake = FakeBackend(analyzer: FakeAnalyzer(holding: [
            CaptionRecognition(text: "last words", start: 1, end: 2, isFinal: true),
        ]))
        let capture = StandInCapture()
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        fake.analyzer.say("last wor")
        await events.wait("the partial") { !$0.isEmpty }

        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["partial:last wor", "confirmed:last words", "finished"])
        #expect(fake.analyzer.finalized.fired)
        #expect(capture.stopped.fired)
        guard case .finished(let take)? = events.all.value.first(where: { if case .finished = $0 { true } else { false } }) else {
            Issue.record("no finished take")
            return
        }
        #expect(take.modelName == AppleSpeechTranscriber.syntheticModelID)
        #expect(ModelCatalog.variant(id: take.modelName)?.engineID == .appleSpeech)
        #expect(take.segments.map(\.text) == ["last words"])
        #expect(take.language == "en")
    }

    @Test("cancel drops the held words, keeps no take and sends no finished")
    func cancelDiscards() async throws {
        let fake = FakeBackend(analyzer: FakeAnalyzer(holding: [
            CaptionRecognition(text: "never shown", start: 1, end: 2, isFinal: true),
        ]))
        let capture = StandInCapture()
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")

        await live.cancel()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts().isEmpty)
        #expect(fake.analyzer.cancelled.fired)
        #expect(!fake.analyzer.finalized.fired)
        #expect(capture.stopped.fired)
    }

    @Test("a capture that ends flushes the held words and then fails with its reason")
    func captureEndFlushesThenFails() async throws {
        let fake = FakeBackend(analyzer: FakeAnalyzer(holding: [
            CaptionRecognition(text: "held", start: 0, end: 1, isFinal: true),
        ]))
        let capture = StandInCapture()
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")

        capture.end(FixedFailureText.systemAudioStopped)
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["confirmed:held", "failed:\(FixedFailureText.systemAudioStopped)"])
        #expect(fake.analyzer.finalized.fired)
        #expect(capture.stopped.fired)
    }

    @Test("a denied capture fails with its own sentence and never builds an analyzer")
    func deniedCapture() async throws {
        let fake = FakeBackend()
        let live = session(fake, StandInCapture(granted: false))
        let events = Events()
        events.collect(try await live.start(options: options()))
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["failed:\(FixedFailureText.systemAudioNotAllowed)"])
        #expect(fake.analyzersMade == 0)
    }

    @Test("an analyzer that fails to start for any other reason reads as a start failure, not a missing model")
    func analyzerStartFailure() async throws {
        struct Unexpected: Error {}
        let capture = StandInCapture()
        let live = session(FakeBackend().failingCreation(with: Unexpected()), capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["failed:\(FixedFailureText.appleSpeechCouldNotStart)"])
        #expect(!capture.started.fired)
    }

    @Test("an analyzer that dies mid-run fails the session")
    func analyzerFailure() async throws {
        let fake = FakeBackend()
        let capture = StandInCapture()
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        fake.analyzer.crash()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["failed:analyzer crashed"])
        #expect(capture.stopped.fired)
    }

    @Test("every analyzer waits for the settle gate")
    func settleGateIsAwaited() async throws {
        let gate = SettleGate(duration: .milliseconds(1))
        gate.beginStop()
        let fake = FakeBackend()
        let capture = StandInCapture()
        let live = session(fake, capture, gate: gate)
        let events = Events()
        events.collect(try await live.start(options: options()))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fake.analyzerRequested.fired, "a stop is still settling")
        #expect(!capture.started.fired)

        gate.endStop()
        await fake.analyzerRequested.wait("the analyzer once the gate settles")
        await capture.started.wait("capture to start")
        await live.cancel()
    }

    @Test("a locale Speech doesn't support fails at start with the Apple Speech sentence")
    func unsupportedLocale() async {
        let fake = FakeBackend().rejecting("it_IT")
        let live = session(fake)
        let text = await startFailure(live, options(language: "it"))
        #expect(text == FixedFailureText.appleSpeechNoModel(LiveSpeechCaption.languageName(Locale(identifier: "it_IT"))))
        #expect(fake.analyzersMade == 0)
    }

    @Test("a failed asset install fails at start with the download sentence")
    func installFailure() async {
        let fake = FakeBackend().failingInstall()
        let text = await startFailure(session(fake), options())
        #expect(text == FixedFailureText.appleSpeechDownloadFailed(LiveSpeechCaption.languageName(Locale(identifier: "en_US"))))
        #expect(fake.prepared.map(\.identifier) == ["en_US"])
    }

    @Test("translating is refused at start")
    func translateRefused() async {
        let fake = FakeBackend()
        let text = await startFailure(session(fake), options(task: .translate))
        #expect(text == FixedFailureText.cannotTranslate("Apple Speech"))
        #expect(fake.prepared.isEmpty)
    }

    @Test("Auto falls back to the app's locale and a named language picks its region")
    func localeChoice() async throws {
        let auto = FakeBackend()
        let first = session(auto)
        _ = try await first.start(options: options(language: nil))
        #expect(auto.prepared.map(\.identifier) == [Locale.current.identifier])
        await first.cancel()

        let italian = FakeBackend()
        let second = session(italian)
        _ = try await second.start(options: options(language: "it"))
        #expect(italian.prepared.map(\.identifier) == ["it_IT"])
        await second.cancel()
    }

    @Test("a stop during the asset install ends the take empty and a cancel throws")
    func endDuringInstall() async throws {
        let stopping = FakeBackend().parkingPrepare()
        let live = session(stopping)
        let started = GuardedTask { try await live.start(options: options()) }
        await stopping.preparing.wait("the install to park")
        await live.stop()
        let events = Events()
        events.collect(try #require(try await started.value("the stopped start")))
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["finished"])
        #expect(stopping.analyzersMade == 0)

        let cancelling = FakeBackend().parkingPrepare()
        let other = session(cancelling)
        let cancelled = GuardedTask { try await other.start(options: options()) }
        await cancelling.preparing.wait("the install to park")
        await other.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value("the cancelled start") }
    }

    @Test("a finalize that never returns ends at the limit and keeps the held words")
    func finalizeNeverReturns() async throws {
        let analyzer = FakeAnalyzer(parksFinalize: true)
        let fake = FakeBackend(analyzer: analyzer)
        let live = session(fake, settleLimit: .milliseconds(300))
        let events = Events()
        events.collect(try await live.start(options: options()))
        analyzer.say("held words")
        await events.wait("the partial") { !$0.isEmpty }

        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["partial:held words", "confirmed:held words", "finished"])
        #expect(analyzer.cancelled.fired)
        analyzer.finalizeGate.open()
    }

    @Test("a cancel while stop waits on the finalize ends the stop and keeps nothing")
    func cancelDuringEnding() async throws {
        let analyzer = FakeAnalyzer(parksFinalize: true)
        let live = session(FakeBackend(analyzer: analyzer), settleLimit: .seconds(3600))
        let events = Events()
        events.collect(try await live.start(options: options()))
        analyzer.say("held words")
        await events.wait("the partial") { !$0.isEmpty }
        let stopping = GuardedTask { await live.stop() }
        await analyzer.finalizeStarted.wait("the finalize to park")

        await live.cancel()
        _ = try await stopping.value("the stop to end")
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["partial:held words"])
        #expect(analyzer.cancelled.fired)
        analyzer.finalizeGate.open()
    }

    @Test("a finalize that throws still confirms the held words and cancels the analyzer")
    func failedFinalizeKeepsHeldWords() async throws {
        let analyzer = FakeAnalyzer(failsToFinalize: true)
        let live = session(FakeBackend(analyzer: analyzer))
        let events = Events()
        events.collect(try await live.start(options: options()))
        analyzer.say("held words")
        await events.wait("the partial") { !$0.isEmpty }

        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["partial:held words", "confirmed:held words", "finished"])
        #expect(analyzer.cancelled.fired)
    }

    @Test("a capture end whose finalize fails still confirms the held words before failing")
    func captureEndWithFailedFinalize() async throws {
        let analyzer = FakeAnalyzer(failsToFinalize: true)
        let capture = StandInCapture()
        let live = session(FakeBackend(analyzer: analyzer), capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        analyzer.say("held words")
        await events.wait("the partial") { !$0.isEmpty }

        capture.end(FixedFailureText.systemAudioStopped)
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == [
            "partial:held words", "confirmed:held words", "failed:\(FixedFailureText.systemAudioStopped)",
        ])
    }

    @Test("a results stream that ends by itself fails the session")
    func resultsEndFails() async throws {
        let analyzer = FakeAnalyzer()
        let capture = StandInCapture()
        let live = session(FakeBackend(analyzer: analyzer), capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        analyzer.say("hello")
        await events.wait("the partial") { !$0.isEmpty }

        analyzer.endResults()
        await events.wait("the stream to end") { Events.ended($0) }
        #expect(events.texts() == ["partial:hello", "failed:\(FixedFailureText.appleSpeechStoppedListening)"])
        #expect(capture.stopped.fired)
    }

    @Test("a stop during analyzer creation holds the settle gate until the late analyzer is cancelled")
    func stopDuringCreation() async throws {
        let analyzer = FakeAnalyzer()
        let fake = FakeBackend(analyzer: analyzer, parksCreation: true)
        let gate = SettleGate(duration: .milliseconds(50))
        let live = session(fake, gate: gate)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await fake.creationGate?.arrivals.wait(atLeast: 1, "creation to park")

        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }
        let waiting = GuardedTask { await gate.waitUntilSettled() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!waiting.isFinished, "the gate settled while the analyzer was still being made")
        #expect(!analyzer.cancelled.fired)

        fake.creationGate?.open()
        await analyzer.cancelled.wait("the late analyzer to be cancelled")
        _ = try await waiting.value("the gate to settle after the late cancel")
    }

    @Test("a cancel during analyzer creation holds the settle gate too")
    func cancelDuringCreation() async throws {
        let analyzer = FakeAnalyzer()
        let fake = FakeBackend(analyzer: analyzer, parksCreation: true)
        let gate = SettleGate(duration: .milliseconds(50))
        let live = session(fake, gate: gate)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await fake.creationGate?.arrivals.wait(atLeast: 1, "creation to park")

        await live.cancel()
        let waiting = GuardedTask { await gate.waitUntilSettled() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!waiting.isFinished)
        fake.creationGate?.open()
        await analyzer.cancelled.wait("the late analyzer to be cancelled")
        _ = try await waiting.value("the gate to settle")
    }

    @Test("a stop while the permission is pending builds no analyzer and starts no capture")
    func stopDuringPermission() async throws {
        let fake = FakeBackend()
        let capture = StandInCapture(parksPermission: true)
        let live = session(fake, capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.permissionGate?.arrivals.wait(atLeast: 1, "the permission to park")

        await live.stop()
        capture.permissionGate?.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fake.analyzersMade == 0)
        #expect(!capture.started.fired)
        #expect(events.texts() == ["finished"])
    }

    @Test("a stop waits for a capture that is still starting, then stops it")
    func stopWaitsForStartingCapture() async throws {
        let capture = StandInCapture(parksStart: true)
        let live = session(FakeBackend(), capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.startGate?.arrivals.wait(atLeast: 1, "the capture start to park")

        let stopping = GuardedTask { await live.stop() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!stopping.isFinished)
        #expect(!capture.stopped.fired)

        capture.startGate?.open()
        _ = try await stopping.value("the stop to end")
        #expect(capture.stopped.fired)
    }

    @Test("a capture end after the stop adds nothing")
    func captureEndAfterStop() async throws {
        let capture = StandInCapture()
        let live = session(FakeBackend(), capture)
        let events = Events()
        events.collect(try await live.start(options: options()))
        await capture.started.wait("capture to start")
        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }

        capture.end(FixedFailureText.systemAudioStopped)
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.texts() == ["finished"])
    }

    @Test("a second start on a running session is refused")
    func secondStartRefused() async throws {
        let live = session(FakeBackend())
        _ = try await live.start(options: options())
        do {
            _ = try await live.start(options: options())
            Issue.record("a second start went through")
        } catch let ParolaError.transcriptionFailed(text) {
            #expect(text == "session already started")
        } catch {
            Issue.record("unexpected \(error)")
        }
        await live.cancel()
    }

    @Test("the take is finished as Apple Speech: its sentences are not merged the way Whisper's are")
    func engineStampKeepsLinesApart() async throws {
        let analyzer = FakeAnalyzer()
        let live = session(FakeBackend(analyzer: analyzer))
        let events = Events()
        events.collect(try await live.start(options: options()))
        analyzer.say("no ending here", 0, 1, final: true)
        analyzer.say("second part.", 1, 2, final: true)
        await events.wait("both finals") { $0.count >= 2 }

        await live.stop()
        await events.wait("the stream to end") { Events.ended($0) }
        guard case .finished(let take)? = events.all.value.first(where: { if case .finished = $0 { true } else { false } }) else {
            Issue.record("no finished take")
            return
        }
        #expect(take.segments.map(\.text) == ["no ending here", "second part."])
    }

    @Test("an empty result clears the partial the panel still shows")
    func emptyResultClearsPartial() async throws {
        let analyzer = FakeAnalyzer()
        let live = session(FakeBackend(analyzer: analyzer))
        let events = Events()
        events.collect(try await live.start(options: options()))
        analyzer.say("hello")
        analyzer.say("  ")
        await events.wait("the clear") { $0.count >= 2 }
        #expect(events.texts() == ["partial:hello", "partial:"])
        await live.cancel()
    }

    @Test("download progress reaches the caller while assets install")
    func progressIsForwarded() async throws {
        let seen = Awaitable<[Double]>([])
        let live = session(FakeBackend())
        _ = try await live.start(options: options(), downloadProgress: { fraction in seen.update { $0.append(fraction) } })
        #expect(seen.value == [0.5])
        await live.cancel()
    }
}

@Suite("Apple Speech caption gating", .timeLimit(.minutes(1)))
struct AppleSpeechCaptionGatingTests {
    private static let apple = AppleSpeechTranscriber.syntheticModelID

    @Test("a dictation or live take on Apple Speech is still refused")
    func takesStayRefused() async {
        let session = StreamingTranscriptionSession(
            modelStore: ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-captions-tests-\(UUID().uuidString)")),
            purpose: .take
        )
        do {
            _ = try await session.start(options: TranscriptionOptions(model: Self.apple))
            Issue.record("a take started on Apple Speech")
        } catch let ParolaError.unsupportedForEngine(text) {
            #expect(text.contains("can't stream"), "\(text)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Analyzer buffer conversion", .timeLimit(.minutes(1)))
struct AnalyzerBufferConverterTests {
    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0) / Float(count) - 0.5 }
    }

    @Test("the capture's own format passes through untouched")
    func sameFormat() throws {
        let converter = try #require(AnalyzerBufferConverter(target: AnalyzerBufferConverter.captureFormat))
        let samples = ramp(1_600)
        let buffer = try #require(converter.buffer(from: samples))
        #expect(buffer.format == AnalyzerBufferConverter.captureFormat)
        #expect(Int(buffer.frameLength) == 1_600)
        #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1_600)) == samples)
    }

    @Test("16-bit mono at 16 kHz keeps the length and scales the values")
    func int16() throws {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AnalyzerBufferConverter(target: target))
        let buffer = try #require(converter.buffer(from: [0.5, -0.5, 0, 0.25]))
        #expect(buffer.format.commonFormat == .pcmFormatInt16)
        #expect(Int(buffer.frameLength) == 4)
        let values = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: 4))
        #expect(abs(Int(values[0]) - 16_384) <= 2)
        #expect(abs(Int(values[1]) + 16_384) <= 2)
        #expect(values[2] == 0)
    }

    @Test("a higher rate and two channels give proportionally more frames")
    func resampledStereo() throws {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let converter = try #require(AnalyzerBufferConverter(target: target))
        var frames = 0
        for _ in 0..<5 {
            let buffer = try #require(converter.buffer(from: ramp(1_600)))
            #expect(buffer.format.channelCount == 2)
            frames += Int(buffer.frameLength)
        }
        #expect(abs(frames - 24_000) <= 1_000, "\(frames)")
    }

    @Test("an empty chunk makes no buffer")
    func empty() throws {
        let converter = try #require(AnalyzerBufferConverter(target: AnalyzerBufferConverter.captureFormat))
        #expect(converter.buffer(from: []) == nil)
    }
}

@Suite("Caption sentences", .timeLimit(.minutes(1)))
struct CaptionSentencesTests {
    private func final(_ text: String, _ start: Double, _ end: Double, runs: [CaptionRecognition.Run] = []) -> CaptionRecognition {
        CaptionRecognition(text: text, start: start, end: end, isFinal: true, runs: runs)
    }

    @Test("a final with several sentences splits into one line each, timed from the runs")
    func splitsWithRunTimes() {
        let runs: [CaptionRecognition.Run] = [
            .init(text: "Buongiorno a tutti. ", start: 0.5, end: 2.0),
            .init(text: "Grazie per essere qui. ", start: 2.4, end: 4.0),
            .init(text: "Iniziamo", start: 4.5, end: 5.2),
        ]
        let text = runs.map(\.text).joined()
        let pieces = CaptionSentences.split(final(text, 0, 6, runs: runs))
        #expect(pieces.map(\.text) == ["Buongiorno a tutti.", "Grazie per essere qui.", "Iniziamo"])
        #expect(pieces.map(\.start) == [0.5, 2.4, 4.5])
        #expect(pieces.map(\.end) == [2.0, 4.0, 5.2])
        #expect(pieces.allSatisfy { $0.isFinal })
    }

    @Test("a sentence that spans two runs takes the first start and the last end")
    func sentenceAcrossRuns() {
        let runs: [CaptionRecognition.Run] = [
            .init(text: "Hello ", start: 0, end: 0.5),
            .init(text: "there. How ", start: 0.5, end: 1.5),
            .init(text: "are you?", start: 1.6, end: 2.5),
        ]
        let pieces = CaptionSentences.split(final(runs.map(\.text).joined(), 0, 2.5, runs: runs))
        #expect(pieces.map(\.text) == ["Hello there.", "How are you?"])
        #expect(pieces[0].start == 0 && pieces[0].end == 1.5)
        #expect(pieces[1].start == 1.6 && pieces[1].end == 2.5)
    }

    @Test("without runs the times are proportional to where each sentence sits")
    func proportionalFallback() {
        let pieces = CaptionSentences.split(final("Aaaa. Bbbb.", 10, 20))
        #expect(pieces.map(\.text) == ["Aaaa.", "Bbbb."])
        #expect(pieces[0].start == 10)
        #expect(abs(pieces[0].end - 15) < 1.5)
        #expect(abs(pieces[1].start - 15) < 1.5)
        #expect(pieces[1].end == 20)
    }

    @Test("runs that don't add up to the text fall back to proportional times")
    func mismatchedRuns() {
        let runs: [CaptionRecognition.Run] = [.init(text: "Other text entirely", start: 99, end: 100)]
        let pieces = CaptionSentences.split(final("One. Two.", 0, 4, runs: runs))
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.start < 4 && $0.end <= 4 })
    }

    @Test("one sentence stays one recognition, unchanged")
    func singleSentence() {
        let single = final("Just one sentence.", 1, 2)
        #expect(CaptionSentences.split(single) == [single])
    }
}

@Suite("Apple Speech caption lines", .timeLimit(.minutes(1)))
struct AppleSpeechCaptionLinesTests {
    @Test("a paragraph final reaches the panel as one confirmed line per sentence")
    func paragraphFinalBecomesLines() async throws {
        let analyzer = FakeAnalyzer()
        let live = session(FakeBackend(analyzer: analyzer))
        let events = Events()
        events.collect(try await live.start(options: options()))
        let runs: [CaptionRecognition.Run] = [
            .init(text: "Prima frase. ", start: 0, end: 1),
            .init(text: "Seconda frase.", start: 1.5, end: 2.5),
        ]
        analyzer.output.yield(CaptionRecognition(
            text: runs.map(\.text).joined(), start: 0, end: 2.5, isFinal: true, runs: runs
        ))
        await events.wait("both lines") { $0.count >= 2 }
        #expect(events.texts() == ["confirmed:Prima frase.", "confirmed:Seconda frase."])
        guard case .confirmed(let second)? = events.all.value.last else { return }
        #expect(second.id == 1 && second.start == 1.5 && second.end == 2.5)
        await live.cancel()
    }
}
