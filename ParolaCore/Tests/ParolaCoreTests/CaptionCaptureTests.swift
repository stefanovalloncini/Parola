import AVFoundation
import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Fixture capture")
struct FixtureCaptureTests {
    @Test("delivers 100 ms chunks, one per clock step, until the file ends")
    func pacing() async {
        let clock = TestClock()
        let samples = (0..<4_000).map { Float($0) }
        let capture = FixtureCapture(samples: samples, clock: clock)
        let received = Awaitable<[[Float]]>([])
        capture.start { chunk in received.update { $0.append(chunk) } }

        await received.wait(until: { $0.count == 1 }, "the first chunk right away")
        #expect(received.value[0].count == 1_600)
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        await received.wait(until: { $0.count == 2 }, "the second chunk one step later")
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        await received.wait(until: { $0.count == 3 }, "the short last chunk")
        #expect(received.value[2].count == 800)
        #expect(received.value.flatMap { $0 } == samples)
        #expect(clock.sleeperCount == 0, "the file is done, nothing waits for more")
    }

    @Test("chunks land on their deadlines even when the clock jumps past several at once")
    func deadlinesAreAbsolute() async {
        let clock = TestClock()
        let capture = FixtureCapture(samples: [Float](repeating: 0.1, count: 160_000), clock: clock)
        let received = Awaitable(0)
        capture.start { _ in received.increment() }
        await received.wait(atLeast: 1, "the first chunk")
        await clock.waitForSleeper()

        clock.advance(by: .milliseconds(1_050))
        await received.wait(atLeast: 11, "every chunk due by 1.05 s, with no sleep of its own per chunk")
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(8_950))
        await received.wait(atLeast: 100, "all 100 chunks of a 10 s file after 10 s")
        #expect(received.value == 100)
    }

    @Test("stop ends delivery")
    func stopEndsDelivery() async {
        let clock = TestClock()
        let capture = FixtureCapture(samples: [Float](repeating: 0.1, count: 16_000), clock: clock)
        let received = Awaitable(0)
        capture.start { _ in received.increment() }
        await received.wait(atLeast: 1, "the first chunk")
        await clock.waitForSleeper()
        capture.stop()
        clock.advance(by: .seconds(1))
        await pollUntil("the paced task to wind down") { clock.sleeperCount == 0 }
        #expect(received.value == 1)
    }

    @Test("the end handler runs when the file runs out, and not after a stop")
    func endHandler() async {
        let clock = TestClock()
        let finished = Awaitable(0)
        let capture = FixtureCapture(samples: [Float](repeating: 0.1, count: 4_000), clock: clock)
        capture.start(onBuffer: { _ in }, onEnd: { finished.increment() })
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        await finished.wait(atLeast: 1, "the end after the last chunk")

        let stopped = Awaitable(0)
        let cut = FixtureCapture(samples: [Float](repeating: 0.1, count: 16_000), clock: clock)
        cut.start(onBuffer: { _ in }, onEnd: { stopped.increment() })
        await clock.waitForSleeper()
        cut.stop()
        clock.advance(by: .seconds(2))
        await pollUntil("the stopped task to wind down") { clock.sleeperCount == 0 }
        #expect(stopped.value == 0)
        #expect(finished.value == 1)
    }

    @Test("no end handler runs after a stop, even once the delivery task has wound down")
    func noEndAfterStop() async {
        let clock = TestClock()
        let ended = Awaitable(0)
        let capture = FixtureCapture(samples: [Float](repeating: 0.1, count: 16_000), clock: clock)
        capture.start(onBuffer: { _ in }, onEnd: { ended.increment() })
        await clock.waitForSleeper()
        capture.stop()
        await capture.finished()
        #expect(ended.value == 0)
    }

    @Test("a missing file throws")
    func missingFile() {
        #expect(throws: ParolaError.self) {
            _ = try FixtureCapture(fixtureURL: URL(fileURLWithPath: "/nonexistent/fixture.wav"))
        }
    }
}

@Suite("Sink capture")
struct SinkCaptureTests {
    @Test("a forwarding writer hands over the samples and touches no file")
    func forwardingWriter() throws {
        let heard = OSAllocatedUnfairLock<[[Float]]>(initialState: [])
        let writer = CaptureFileWriter.forwarding { chunk in heard.withLock { $0.append(chunk) } }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 4
        for index in 0..<4 { buffer.floatChannelData?[0][index] = Float(index) }
        writer.write(buffer)
        buffer.floatChannelData?[0][0] = 99
        #expect(heard.withLock { $0 } == [[0, 1, 2, 3]], "the samples were copied before the buffer was reused")
        #expect(writer.failure == nil)
    }

    #if os(macOS)
    @Test("sink-mode sources keep no file")
    @available(macOS 14.2, *)
    func sourcesKeepNoFile() async {
        let system = SystemAudioSource(samples: { _ in })
        #expect(await system.inFlightURL() == nil)
        let tap = ProcessTapAudioSource(processObjects: [], samples: { _ in })
        #expect(await tap.inFlightURL() == nil)
        await system.cancel()
        await tap.cancel()
        #expect(await SystemAudioSource().inFlightURL() != nil, "a meeting source still records to its file")
    }
    #endif
}

#if os(macOS)

private actor StubSource: LiveAudioSource, TargetsGoneReporting {
    let sink: @Sendable ([Float]) -> Void
    private let gate: UninterruptibleGate?
    private(set) var started = false
    private(set) var cancelCount = 0
    private let startFailure: (any Error)?
    private var endHandler: (@Sendable () -> Void)?

    func whenCaptureEnds(_ handler: @escaping @Sendable () -> Void) async { endHandler = handler }

    func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async { endHandler = handler }

    func watchedProcessObjects() async -> [UInt32] { watched }

    func rewatchTargets(_ survivors: [UInt32], _ handler: @escaping @Sendable () -> Void) async {
        watched = survivors
        rewatches += 1
        endHandler = handler
    }

    func end() { endHandler?() }

    private(set) var rewatches = 0
    private var watched: [UInt32]

    init(
        sink: @escaping @Sendable ([Float]) -> Void, watched: [UInt32] = [], gate: UninterruptibleGate? = nil,
        startFailure: (any Error)? = nil
    ) {
        self.watched = watched
        self.sink = sink
        self.gate = gate
        self.startFailure = startFailure
    }

    func start() async throws {
        if let gate { await gate.wait() }
        if let startFailure { throw startFailure }
        started = true
    }

    func prepare() async throws -> URL { throw CancellationError() }
    func cancel() async { cancelCount += 1 }
}

private final class FakeEnvironment: Sendable {
    private struct State {
        var screenGranted = true
        var tap = SystemAudioRecordingPermission.granted
        var tapAfterProbe = SystemAudioRecordingPermission.granted
        var probes = 0
        var sources: [StubSource] = []
        var processObjects: [UInt32] = [7]
        var outputting: Set<UInt32> = []
        var fixture: URL?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setProcessObjects(_ objects: [UInt32]) { state.withLock { $0.processObjects = objects } }
    func setOutputting(_ objects: Set<UInt32>) { state.withLock { $0.outputting = objects } }
    let probeGate: UninterruptibleGate?
    let startGate: UninterruptibleGate?
    let startFailure: (any Error)?
    let clock = TestClock()

    init(
        screenGranted: Bool = true, tap: SystemAudioRecordingPermission = .granted,
        tapAfterProbe: SystemAudioRecordingPermission = .granted,
        processObjects: [UInt32] = [7], fixture: URL? = nil,
        probeGate: UninterruptibleGate? = nil, startGate: UninterruptibleGate? = nil, startFailure: (any Error)? = nil
    ) {
        state.withLock {
            $0.screenGranted = screenGranted
            $0.tap = tap
            $0.tapAfterProbe = tapAfterProbe
            $0.processObjects = processObjects
            $0.fixture = fixture
        }
        self.probeGate = probeGate
        self.startGate = startGate
        self.startFailure = startFailure
    }

    var probes: Int { state.withLock { $0.probes } }
    var sources: [StubSource] { state.withLock { $0.sources } }

    var environment: CaptionCaptureEnvironment {
        CaptionCaptureEnvironment(
            permissions: CapturePermissionCheck(
                screenRecordingGranted: { [self] in state.withLock { $0.screenGranted } },
                tapStatus: { [self] in state.withLock { $0.probes > 0 ? $0.tapAfterProbe : $0.tap } },
                probeTapConsent: { [self] in
                    state.withLock { $0.probes += 1 }
                    await probeGate?.wait()
                }
            ),
            fixtureURL: { [self] in state.withLock { $0.fixture } },
            processObjects: { [self] _ in state.withLock { $0.processObjects.map { $0 } } },
            makeSystemSource: { [self] sink in make(sink) },
            makeTapSource: { [self] objects, sink in make(sink, watched: objects) },
            startTimeout: .seconds(15),
            clock: clock,
            isRunningOutput: { [self] object in state.withLock { $0.outputting.contains(object) } }
        )
    }

    private func make(_ sink: @escaping @Sendable ([Float]) -> Void, watched: [UInt32] = []) -> StubSource {
        let source = StubSource(sink: sink, watched: watched, gate: startGate, startFailure: startFailure)
        state.withLock { $0.sources.append(source) }
        return source
    }
}

@Suite("External caption capture")
struct ExternalCaptionCaptureTests {
    private let app = CaptionSource.app(bundleID: "us.zoom.xos")

    @Test("system audio without Screen Recording is refused with its own text and starts nothing")
    func systemDenied() async {
        let fake = FakeEnvironment(screenGranted: false)
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        #expect(await capture.requestPermission() == false)
        #expect(capture.deniedText == FixedFailureText.systemAudioNotAllowed)
        #expect(fake.sources.isEmpty)
    }

    @Test("an app tap denied in System Settings is refused without raising the prompt")
    func tapDenied() async {
        let fake = FakeEnvironment(tap: .denied)
        let capture = CaptionCapture.external(app, environment: fake.environment)
        #expect(await capture.requestPermission() == false)
        #expect(capture.deniedText == FixedFailureText.appAudioNotAllowed)
        #expect(fake.probes == 0)
        #expect(fake.sources.isEmpty)
    }

    @Test("an undetermined tap raises the prompt once, then starts when it is allowed")
    func tapUndeterminedThenAllowed() async throws {
        let fake = FakeEnvironment(tap: .undetermined, tapAfterProbe: .granted)
        let capture = CaptionCapture.external(app, environment: fake.environment)
        #expect(await capture.requestPermission() == true)
        #expect(fake.probes == 1)
        try await capture.start { _ in }
        #expect(await fake.sources.first?.started == true)
    }

    @Test("an undetermined tap the user then refuses is a denial")
    func tapUndeterminedThenRefused() async {
        let fake = FakeEnvironment(tap: .undetermined, tapAfterProbe: .denied)
        let capture = CaptionCapture.external(app, environment: fake.environment)
        #expect(await capture.requestPermission() == false)
        #expect(fake.sources.isEmpty)
    }

    @Test("an app with no audio process fails with the not-playing text and starts no tap")
    func appNotPlaying() async {
        let fake = FakeEnvironment(processObjects: [])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        _ = await capture.requestPermission()
        await #expect(throws: CaptionCaptureError(text: FixedFailureText.appNotPlayingAudio("us.zoom.xos"))) {
            try await capture.start { _ in }
        }
        #expect(fake.sources.isEmpty)
    }

    @Test("samples from the source reach the session's buffer callback")
    func samplesFlow() async throws {
        let fake = FakeEnvironment()
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        _ = await capture.requestPermission()
        let heard = Awaitable<[[Float]]>([])
        try await capture.start { chunk in heard.update { $0.append(chunk) } }
        let source = try #require(fake.sources.first)
        let tenth = (0..<1_600).map { Float($0) }
        source.sink(tenth)
        #expect(heard.value == [tenth])
    }

    @Test("a stop that lands while the source is starting cancels it once it is up")
    func stopDuringStart() async throws {
        let gate = UninterruptibleGate()
        let fake = FakeEnvironment(startGate: gate)
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        _ = await capture.requestPermission()
        let starting = GuardedTask { try await capture.start { _ in } }
        await pollUntil("the source to be made") { fake.sources.count == 1 }
        capture.stop()
        gate.open()
        _ = try await starting.value("the start to return")
        let source = try #require(fake.sources.first)
        await pollUntil("the source to be cancelled") { await source.cancelCount >= 1 }
    }

    @Test("callback-sized buffers reach the session as 100 ms ones, with the remainder flushed on stop")
    func rechunksToHundredMilliseconds() async throws {
        let fake = FakeEnvironment()
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        _ = await capture.requestPermission()
        let heard = Awaitable<[[Float]]>([])
        try await capture.start { chunk in heard.update { $0.append(chunk) } }
        let source = try #require(fake.sources.first)
        for _ in 0..<25 { source.sink([Float](repeating: 0.2, count: 160)) }
        #expect(heard.value.map(\.count) == [1_600, 1_600], "4 000 samples make two full chunks")
        capture.stop()
        #expect(heard.value.map(\.count) == [1_600, 1_600, 800], "the 800-sample remainder is flushed")
    }

    @Test("a stop during a start that never returns ends the wait without the deadline")
    func stopEndsAParkedStart() async throws {
        let gate = UninterruptibleGate()
        let fake = FakeEnvironment(startGate: gate)
        let capture = CaptionCapture.external(app, environment: fake.environment)
        _ = await capture.requestPermission()
        let starting = GuardedTask { try await capture.start { _ in } }
        await pollUntil("the source to be made") { fake.sources.count == 1 }
        capture.stop()
        _ = try await starting.value("the start to return on stop, with the deadline still far off", timeout: .seconds(5))
        gate.open()
    }

    @Test("a tap that can't be made fails instead of listening to something else")
    func tapUnavailableThrows() async {
        struct NoTap: Error, Equatable {}
        let fake = FakeEnvironment()
        var env = fake.environment
        env.makeTapSource = { _, _ in throw NoTap() }
        let capture = CaptionCapture.external(app, environment: env)
        _ = await capture.requestPermission()
        await #expect(throws: NoTap()) { try await capture.start { _ in } }
        #expect(fake.sources.isEmpty)
    }

    @Test("a start that never returns gives up at the deadline with the permission text")
    func startTimesOut() async throws {
        let gate = UninterruptibleGate()
        let fake = FakeEnvironment(startGate: gate)
        let capture = CaptionCapture.external(app, environment: fake.environment)
        _ = await capture.requestPermission()
        let starting = GuardedTask { try await capture.start { _ in } }
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(15))
        await #expect(throws: CaptionCaptureError(text: FixedFailureText.appAudioNotAllowed)) {
            _ = try await starting.value("the start to give up")
        }
        let source = try #require(fake.sources.first)
        await pollUntil("the parked source to be cancelled") { await source.cancelCount >= 1 }
        gate.open()
    }

    @Test("a source that ends by itself reports the source's own sentence once")
    func endReportsOnce() async throws {
        for (source, objectsAfter, text) in [
            (CaptionSource.systemAudio, [UInt32(7)], FixedFailureText.systemAudioStopped),
            (app, [], FixedFailureText.appQuit("us.zoom.xos")),
        ] {
            let fake = FakeEnvironment()
            let capture = CaptionCapture.external(source, environment: fake.environment)
            let ended = Awaitable<[String]>([])
            capture.whenEnded?({ text in ended.update { $0.append(text) } })
            _ = await capture.requestPermission()
            try await capture.start { _ in }
            fake.setProcessObjects(objectsAfter)
            let stub = try #require(fake.sources.first)
            await stub.end()
            await stub.end()
            if source != .systemAudio {
                await fake.clock.waitForSleeper()
                fake.clock.advance(by: .seconds(1))
            }
            await ended.wait(until: { $0.count == 1 }, "the end to be reported")
            #expect(ended.value == [text])
        }
    }

    @Test("an app that still has audio processes after its tap lost one is not reported as quit", arguments: [
        [UInt32(1), 3],
        [UInt32(9)],
        [UInt32(20), 21],
    ])
    func appStillThere(after: [UInt32]) async throws {
        let fake = FakeEnvironment(processObjects: [1, 2])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        fake.setProcessObjects(after)
        await fake.sources.first?.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(1))
        await ended.wait(until: { $0.count == 1 }, "the end to be reported")
        #expect(ended.value == [FixedFailureText.appStoppedSending("us.zoom.xos")])
    }

    @Test("a multi-process app whose child exits and then its parent a moment later reads as quit")
    func familyQuitsInTheWindow() async throws {
        let fake = FakeEnvironment(processObjects: [1, 2])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        fake.setProcessObjects([1])
        await fake.sources.first?.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .milliseconds(300))
        fake.setProcessObjects([])
        fake.clock.advance(by: .milliseconds(700))
        await ended.wait(until: { $0.count == 1 }, "the end to be reported")
        #expect(ended.value == [FixedFailureText.appQuit("us.zoom.xos")])
    }

    @Test("a helper that leaves and comes back inside the window reads as stopped sending audio")
    func helperRespawnsInTheWindow() async throws {
        let fake = FakeEnvironment(processObjects: [2])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        fake.setProcessObjects([])
        await fake.sources.first?.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .milliseconds(300))
        fake.setProcessObjects([5])
        fake.clock.advance(by: .milliseconds(700))
        await ended.wait(until: { $0.count == 1 }, "the end to be reported")
        #expect(ended.value == [FixedFailureText.appStoppedSending("us.zoom.xos")])
    }

    @Test("a helper that leaves while the main process still plays does not end the capture, and the watch moves to the survivors")
    func helperLeavesMainStillPlays() async throws {
        let fake = FakeEnvironment(processObjects: [1, 2])
        fake.setOutputting([1])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        let stub = try #require(fake.sources.first)
        fake.setProcessObjects([1])
        await stub.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(1))
        await pollUntil("the watch to move") { await stub.rewatches == 1 }
        #expect(ended.value.isEmpty)
        #expect(await stub.watchedProcessObjects() == [1])
    }

    @Test("survivors that are all quiet are not an end either")
    func survivorsQuiet() async throws {
        let fake = FakeEnvironment(processObjects: [1, 2])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        let stub = try #require(fake.sources.first)
        fake.setProcessObjects([1])
        await stub.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(1))
        await pollUntil("the watch to move") { await stub.rewatches == 1 }
        #expect(ended.value.isEmpty)
    }

    @Test("after the watch moves, the app quitting later still ends the capture once")
    func quitAfterRearm() async throws {
        let fake = FakeEnvironment(processObjects: [1, 2])
        fake.setOutputting([1])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        let stub = try #require(fake.sources.first)
        fake.setProcessObjects([1])
        await stub.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(1))
        await pollUntil("the watch to move") { await stub.rewatches == 1 }
        fake.setProcessObjects([])
        await stub.end()
        await fake.clock.waitForSleeper()
        fake.clock.advance(by: .seconds(1))
        await ended.wait(until: { $0.count == 1 }, "the end to be reported")
        #expect(ended.value == [FixedFailureText.appQuit("us.zoom.xos")])
    }

    @Test("a stop during the settle wait cancels it")
    func stopCancelsTheSettle() async throws {
        let fake = FakeEnvironment(processObjects: [1])
        let capture = CaptionCapture.external(app, environment: fake.environment)
        let ended = Awaitable(0)
        capture.whenEnded?({ _ in ended.increment() })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        fake.setProcessObjects([])
        await fake.sources.first?.end()
        await fake.clock.waitForSleeper()
        capture.stop()
        await pollUntil("the settle wait to be cancelled") { fake.clock.sleeperCount == 0 }
        fake.clock.advance(by: .seconds(2))
        #expect(ended.value == 0)
    }

    @Test("an end reported before the handler is registered is replayed to it")
    func earlyEndIsReplayed() async throws {
        let fake = FakeEnvironment()
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        await fake.sources.first?.end()
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        #expect(ended.value == [FixedFailureText.systemAudioStopped])
    }

    @Test("an end after a stop is not reported")
    func endAfterStop() async throws {
        let fake = FakeEnvironment()
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        let ended = Awaitable(0)
        capture.whenEnded?({ _ in ended.increment() })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        capture.stop()
        await fake.sources.first?.end()
        #expect(ended.value == 0)
    }

    @Test("a fixture that runs out is an end")
    func fixtureEnd() async throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("caption-end-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
            buffer.frameLength = 800
            try file.write(from: buffer)
        }
        let fake = FakeEnvironment(fixture: wav)
        let capture = CaptionCapture.external(.systemAudio, environment: fake.environment)
        let ended = Awaitable<[String]>([])
        capture.whenEnded?({ text in ended.update { $0.append(text) } })
        _ = await capture.requestPermission()
        try await capture.start { _ in }
        await ended.wait(until: { $0.count == 1 }, "the fixture to run out")
        #expect(ended.value == [FixedFailureText.systemAudioStopped])
    }

    @Test("a fixture replaces the capture and skips every permission check")
    func fixtureSkipsPermissions() async throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("caption-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
            buffer.frameLength = 800
            try file.write(from: buffer)
        }
        let fake = FakeEnvironment(screenGranted: false, tap: .denied, fixture: wav)
        for source in [CaptionSource.systemAudio, app] {
            let capture = CaptionCapture.external(source, environment: fake.environment)
            #expect(await capture.requestPermission() == true)
            let heard = Awaitable(0)
            try await capture.start { chunk in heard.update { $0 += chunk.count } }
            await heard.wait(atLeast: 800, "the fixture's samples")
            capture.stop()
        }
        #expect(fake.sources.isEmpty)
        #expect(fake.probes == 0)
    }
}

@Suite("Capture end detection")
struct CaptureEndDetectionTests {
    private final class ProcessList: Sendable {
        private let objects = OSAllocatedUnfairLock<[UInt32]>(initialState: [])
        private let notify = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        private let removals = OSAllocatedUnfairLock(initialState: 0)

        init(_ objects: [UInt32]) { self.objects.withLock { $0 = objects } }

        var current: [UInt32] { objects.withLock { $0 } }
        var unsubscribed: Int { removals.withLock { $0 } }

        func subscribe(_ block: @escaping @Sendable () -> Void) -> ProcessEndWatch.Unsubscribe {
            notify.withLock { $0 = block }
            return { [self] in removals.withLock { $0 += 1 } }
        }

        func set(_ new: [UInt32]) {
            objects.withLock { $0 = new }
            notify.withLock { $0 }?()
        }
    }

    @Test("the watch fires once, as soon as any watched object has left the list")
    func firesWhenAnyGone() {
        let list = ProcessList([7, 8, 9])
        let fired = Awaitable(0)
        let watch = ProcessEndWatch(
            objects: [7, 8], currentObjects: { list.current }, subscribe: list.subscribe, onGone: { fired.increment() }
        )
        list.set([7, 8, 9, 11])
        #expect(fired.value == 0, "a new process appearing is not an end")
        list.set([8, 9])
        list.set([])
        #expect(fired.value == 1)
        #expect(list.unsubscribed == 1)
        watch.check()
        #expect(fired.value == 1)
    }

    @Test("the watch fires when a helper is replaced, when every id changes, and when the app is gone", arguments: [
        [UInt32(1), 3],
        [UInt32(20), 21],
        [UInt32](),
    ])
    func firesOnEachShape(after: [UInt32]) {
        let list = ProcessList([1, 2])
        let fired = Awaitable(0)
        let watch = ProcessEndWatch(
            objects: [1, 2], currentObjects: { list.current }, subscribe: list.subscribe, onGone: { fired.increment() }
        )
        list.set(after)
        #expect(fired.value == 1)
        watch.cancel()
    }

    @Test("an app that stays in the list, however quiet, is not an end")
    func quietIsNotAnEnd() {
        let list = ProcessList([7])
        let fired = Awaitable(0)
        let watch = ProcessEndWatch(
            objects: [7], currentObjects: { list.current }, subscribe: list.subscribe, onGone: { fired.increment() }
        )
        list.set([7, 11])
        list.set([7])
        #expect(fired.value == 0)
        watch.cancel()
        list.set([])
        #expect(fired.value == 0, "a cancelled watch stays quiet")
        #expect(list.unsubscribed == 1)
    }

    private final class FakeHardware: Sendable {
        private let calls = OSAllocatedUnfairLock<(adds: [UInt], removes: [UInt])>(initialState: ([], []))
        var adds: [UInt] { calls.withLock { $0.adds } }
        var removes: [UInt] { calls.withLock { $0.removes } }

        var hardware: ProcessListObserver.Hardware {
            .init(
                add: { [self] token in calls.withLock { $0.adds.append(token) }; return noErr },
                remove: { [self] token in calls.withLock { $0.removes.append(token) }; return noErr }
            )
        }
    }

    @Test("removing the observer makes the hardware remove call once, with the token it was added under")
    func observerRemoval() {
        let fake = FakeHardware()
        let stop = ProcessListObserver.observe(on: .global(), hardware: fake.hardware, {})
        #expect(fake.adds.count == 1)
        stop()
        stop()
        #expect(fake.removes == fake.adds)
    }

    @Test("a delivery that is queued when the observer is removed never reaches it")
    func noDeliveryAfterRemoval() {
        let fake = FakeHardware()
        let queue = DispatchQueue(label: "observer-test")
        let reached = Awaitable(0)
        let stop = ProcessListObserver.observe(on: queue, hardware: fake.hardware, { reached.increment() })
        let token = fake.adds[0]
        let parked = DispatchSemaphore(value: 0)
        queue.async { parked.wait() }
        ProcessListObserver.deliver(token: token)
        stop()
        parked.signal()
        queue.sync {}
        #expect(reached.value == 0)

        let live = ProcessListObserver.observe(on: queue, hardware: fake.hardware, { reached.increment() })
        ProcessListObserver.deliver(token: fake.adds[1])
        queue.sync {}
        #expect(reached.value == 1)
        live()
    }

    @Test("a tap source ignores the system-audio end hook, so only the targets-gone signal ends it")
    @available(macOS 14.2, *)
    func tapWhenCaptureEndsIsNoOp() async {
        let list = ProcessList([7])
        let source = ProcessTapAudioSource(
            processObjects: [7], samples: { _ in }, processList: { list.current }, subscribeToProcessList: list.subscribe
        )
        let fired = Awaitable(0)
        await source.whenCaptureEnds { fired.increment() }
        list.set([])
        #expect(fired.value == 0)
    }

    @Test("a tap source reports its app leaving the process list and not a stop")
    @available(macOS 14.2, *)
    func tapSourceEnd() async {
        let list = ProcessList([7])
        let source = ProcessTapAudioSource(
            processObjects: [7], samples: { _ in }, processList: { list.current }, subscribeToProcessList: list.subscribe
        )
        let fired = Awaitable(0)
        await source.whenTargetsGone { fired.increment() }
        list.set([])
        #expect(fired.value == 1)

        let stopped = ProcessTapAudioSource(
            processObjects: [7], samples: { _ in }, processList: { list.current }, subscribeToProcessList: list.subscribe
        )
        list.set([7])
        let quiet = Awaitable(0)
        await stopped.whenTargetsGone { quiet.increment() }
        await stopped.cancel()
        list.set([])
        #expect(quiet.value == 0)
    }

    @Test("a system source in sink mode reports ScreenCaptureKit stopping it, and not after a cancel")
    func systemSinkModeEnd() async {
        struct Dropped: Error {}
        let source = SystemAudioSource(samples: { _ in })
        let fired = Awaitable(0)
        await source.whenCaptureEnds { fired.increment() }
        await source.captureEnded(Dropped())
        await source.captureEnded(Dropped())
        #expect(fired.value == 1)

        let cancelled = SystemAudioSource(samples: { _ in })
        let quiet = Awaitable(0)
        await cancelled.whenCaptureEnds { quiet.increment() }
        await cancelled.cancel()
        await cancelled.captureEnded(Dropped())
        #expect(quiet.value == 0)
    }
}

private actor HandlerKeepingSource: LiveAudioSource, TargetsGoneReporting {
    func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async { endHandler = handler }
    private var endHandler: (@Sendable () -> Void)?
    func whenCaptureEnds(_ handler: @escaping @Sendable () -> Void) async { endHandler = handler }
    func start() async throws {}
    func prepare() async throws -> URL { throw CancellationError() }
    func cancel() async {}
}

private final class Sentinel: Sendable {}

@Suite("Caption capture lifetime")
struct CaptionCaptureLifetimeTests {
    @Test("a source that keeps its end handler does not keep a stopped capture alive")
    func stoppedCaptureIsReleased() async throws {
        weak var sentinel: Sentinel?
        let source = HandlerKeepingSource()
        do {
            let held = Sentinel()
            sentinel = held
            let env = CaptionCaptureEnvironment(
                permissions: CapturePermissionCheck(screenRecordingGranted: { true }, tapStatus: { .granted }, probeTapConsent: {}),
                fixtureURL: { nil },
                processObjects: { _ in [7] },
                makeSystemSource: { _ in source },
                makeTapSource: { _, _ in source },
                startTimeout: .seconds(15),
                clock: ContinuousClock()
            )
            let capture = CaptionCapture.external(.systemAudio, environment: env)
            _ = await capture.requestPermission()
            try await capture.start { _ in withExtendedLifetime(held) {} }
            capture.stop()
        }
        await pollUntil("the capture to be released") { sentinel == nil }
        withExtendedLifetime(source) {}
    }
}

#endif
