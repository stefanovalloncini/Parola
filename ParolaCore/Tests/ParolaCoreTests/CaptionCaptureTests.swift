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

private actor StubSource: LiveAudioSource {
    let sink: @Sendable ([Float]) -> Void
    private let gate: UninterruptibleGate?
    private(set) var started = false
    private(set) var cancelCount = 0
    private let startFailure: (any Error)?

    init(sink: @escaping @Sendable ([Float]) -> Void, gate: UninterruptibleGate? = nil, startFailure: (any Error)? = nil) {
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
        var fixture: URL?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
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
            makeTapSource: { [self] _, sink in make(sink) },
            startTimeout: .seconds(15),
            clock: clock
        )
    }

    private func make(_ sink: @escaping @Sendable ([Float]) -> Void) -> StubSource {
        let source = StubSource(sink: sink, gate: startGate, startFailure: startFailure)
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

#endif
