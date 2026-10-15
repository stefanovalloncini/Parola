import AVFoundation
import Foundation
import Testing
import os
@testable import ParolaCore

private final class FakeAnalyzer: CaptionAnalyzing {
    let recognitions: AsyncThrowingStream<CaptionRecognition, any Error>
    private let output: AsyncThrowingStream<CaptionRecognition, any Error>.Continuation
    private let held: OSAllocatedUnfairLock<[CaptionRecognition]>
    let fed = Awaitable(0)
    let finalized = TestSignal()
    let cancelled = TestSignal()
    let failsToFinalize: Bool

    init(holding held: [CaptionRecognition] = [], failsToFinalize: Bool = false) {
        (recognitions, output) = AsyncThrowingStream<CaptionRecognition, any Error>.makeStream()
        self.held = OSAllocatedUnfairLock(initialState: held)
        self.failsToFinalize = failsToFinalize
    }

    func say(_ text: String, _ start: Double = 0, _ end: Double = 1, final: Bool = false) {
        output.yield(CaptionRecognition(text: text, start: start, end: end, isFinal: final))
    }

    func crash() {
        output.finish(throwing: CaptionCaptureError(text: "analyzer crashed"))
    }

    func feed(_ samples: [Float]) { fed.increment() }

    func finalize() async throws {
        finalized.fire()
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let analyzerRequested = TestSignal()
    private let analyzerToMake: FakeAnalyzer

    init(analyzer: FakeAnalyzer = FakeAnalyzer()) {
        analyzerToMake = analyzer
    }

    var prepared: [Locale] { state.withLock { $0.prepared } }
    var analyzer: FakeAnalyzer { analyzerToMake }
    var analyzersMade: Int { state.withLock { $0.analyzers.count } }

    func rejecting(_ identifier: String) -> Self {
        state.withLock { _ = $0.unsupported.insert(identifier) }
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

    init(granted: Bool = true) {
        self.granted = granted
    }

    var capture: CaptionCapture {
        CaptionCapture(
            requestPermission: { [granted] in granted },
            deniedText: FixedFailureText.systemAudioNotAllowed,
            start: { [self] onBuffer in
                state.withLock { $0.onBuffer = onBuffer }
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
    _ fake: FakeBackend, _ capture: StandInCapture = StandInCapture(), gate: SettleGate = SettleGate(duration: .milliseconds(1))
) -> AppleSpeechCaptionSession {
    AppleSpeechCaptionSession(
        source: .systemAudio, backend: fake.backend, capture: { _ in capture.capture }, settleGate: gate
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

@Suite("Apple Speech captions")
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
        #expect(text == FixedFailureText.appleSpeechNoModel("it_IT"))
        #expect(fake.analyzersMade == 0)
    }

    @Test("a failed asset install fails at start and a retry on a fresh session prepares again")
    func installFailure() async {
        let fake = FakeBackend().failingInstall()
        let text = await startFailure(session(fake), options())
        #expect(text == FixedFailureText.appleSpeechDownloadFailed("en_US"))
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

    @Test("download progress reaches the caller while assets install")
    func progressIsForwarded() async throws {
        let seen = Awaitable<[Double]>([])
        let live = session(FakeBackend())
        _ = try await live.start(options: options(), downloadProgress: { fraction in seen.update { $0.append(fraction) } })
        #expect(seen.value == [0.5])
        await live.cancel()
    }
}

@Suite("Apple Speech caption gating")
struct AppleSpeechCaptionGatingTests {
    private static let apple = AppleSpeechTranscriber.syntheticModelID

    @Test("every catalog engine can caption")
    func everyEngineCaptions() {
        for variant in ModelCatalog.all {
            #expect(ModelCatalog.canCaption(id: variant.id), "\(variant.id)")
        }
        #expect(!ModelCatalog.canStream(id: Self.apple))
    }

    @Test("captions on Apple Speech get the Apple Speech session and takes get the refusing one")
    func factoryRouting() {
        let captions = StreamingTranscriberFactory.make(purpose: .captions, model: Self.apple)
        #expect(captions is AppleSpeechCaptionSession)
        let whisper = StreamingTranscriberFactory.make(purpose: .captions, model: "openai_whisper-tiny")
        #expect(whisper is StreamingTranscriptionSession)
        let take = StreamingTranscriberFactory.make(purpose: .take, model: Self.apple)
        #expect(take is StreamingTranscriptionSession)
    }

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

@Suite("Analyzer buffer conversion")
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
