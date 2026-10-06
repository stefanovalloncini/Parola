import Foundation
import Testing
import ParolaCore
import ParolaSpeech

@Suite("MockSpeechRenderer")
struct MockSpeechRendererTests {
    private let voice = VoiceID.appleAutomatic

    private final class Collector: Sendable {
        let chunks = Awaitable<[PCMChunk]>([])
        let task: GuardedTask<Void>

        init(_ stream: AsyncThrowingStream<PCMChunk, any Error>) {
            let chunks = chunks
            task = GuardedTask {
                for try await chunk in stream {
                    chunks.update { $0.append(chunk) }
                }
            }
        }

        var samples: [Float] { chunks.value.flatMap(\.samples) }
    }

    private final class Events: Sendable {
        let held = Awaitable(0)
        let ended = Awaitable(0)

        var observer: MockSpeechRenderer.Observer {
            { [held, ended] event in
                switch event {
                case .started: break
                case .held: held.increment()
                case .ended: ended.increment()
                }
            }
        }
    }

    @Test("emits the samples its text length asks for, at the configured rate")
    func sampleCount() async throws {
        let renderer = MockSpeechRenderer(sampleRate: 16_000, secondsPerCharacter: 0.05, chunkSeconds: 0.1)
        let stream = try await renderer.render(text: "Hello there", unitID: 3, voice: voice, language: "en")
        let collector = Collector(stream)
        try await collector.task.value("the render to finish")

        let chunks = collector.chunks.value
        let sampleCounts = chunks.map(\.samples.count)
        let units = Set(chunks.map(\.unitID))
        let rates = Set(chunks.map(\.sampleRate))
        let loudest = collector.samples.map(abs).max()
        #expect(sampleCounts == [1_600, 1_600, 1_600, 1_600, 1_600, 800])
        #expect(units == [3])
        #expect(rates == [16_000])
        #expect(loudest == 0)
        let rendered = await renderer.rendered
        #expect(rendered == [.init(unitID: 3, text: "Hello there", voice: voice, language: "en")])
    }

    @Test("a tone is a continuous sine across chunks")
    func tone() async throws {
        let renderer = MockSpeechRenderer(
            sampleRate: 8_000, secondsPerCharacter: 0.1, chunkSeconds: 0.05, toneFrequency: 440
        )
        let stream = try await renderer.render(text: "Tone", unitID: 0, voice: voice, language: "en")
        let collector = Collector(stream)
        try await collector.task.value("the render to finish")

        let samples = collector.samples
        #expect(samples.count == 3_200)
        let expected = (0..<samples.count).map { index in
            Float(MockSpeechRenderer.toneAmplitude * sin(2 * Double.pi * 440 * Double(index) / 8_000))
        }
        let worst = zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
        let loudest = samples.max() ?? 0
        #expect(worst < 1e-5)
        #expect(loudest > 0)
    }

    @Test("failAtUnit throws for that unit before any audio, and other units render")
    func failAtUnit() async throws {
        let renderer = MockSpeechRenderer(failAtUnit: 2)
        let failing = Collector(try await renderer.render(text: "Two", unitID: 2, voice: voice, language: "en"))
        await #expect(throws: MockSpeechRenderer.Failure(unitID: 2)) {
            try await failing.task.value("the failing render to end")
        }
        #expect(failing.chunks.value.isEmpty)

        let other = Collector(try await renderer.render(text: "Three", unitID: 3, voice: voice, language: "en"))
        try await other.task.value("the next render to finish")
        #expect(!other.chunks.value.isEmpty)

        await renderer.setFailAtUnit(nil)
        let again = Collector(try await renderer.render(text: "Two", unitID: 2, voice: voice, language: "en"))
        try await again.task.value("the cleared unit to render")
        #expect(!again.chunks.value.isEmpty)
    }

    @Test("holdStart parks a render before its first chunk until released")
    func holdStart() async throws {
        let events = Events()
        let renderer = MockSpeechRenderer(secondsPerCharacter: 0.05, observer: events.observer)
        await renderer.holdStart()
        let collector = Collector(try await renderer.render(text: "Held", unitID: 0, voice: voice, language: "en"))

        try #require(await events.held.wait(atLeast: 1, "the render to park at the hold"))
        #expect(collector.chunks.value.isEmpty)
        #expect(events.ended.value == 0)
        #expect(!collector.task.isFinished)

        await renderer.releaseStart()
        try await collector.task.value("the released render to finish")
        try #require(await events.ended.wait(atLeast: 1, "the released render to end"))
        #expect(collector.samples.count == 4_800)
    }

    @Test("a render started while another runs is recorded, not trapped")
    func overlappingRenders() async throws {
        let events = Events()
        let renderer = MockSpeechRenderer(observer: events.observer)
        await renderer.holdStart()
        let first = Collector(try await renderer.render(text: "One", unitID: 0, voice: voice, language: "en"))
        try #require(await events.held.wait(atLeast: 1, "the first render to park"))
        let second = Collector(try await renderer.render(text: "Two", unitID: 1, voice: voice, language: "en"))

        let peak = await renderer.peakConcurrentRenders
        let violations = await renderer.violations
        #expect(peak == 2)
        #expect(violations == [.concurrentRender(unitID: 1)])

        await renderer.releaseStart()
        try await first.task.value("the first render to finish")
        try await second.task.value("the second render to finish")
    }

    @Test("renders one after another never overlap")
    func sequentialRenders() async throws {
        let events = Events()
        let renderer = MockSpeechRenderer(observer: events.observer)
        for unit in 0..<3 {
            let collector = Collector(try await renderer.render(text: "Unit", unitID: unit, voice: voice, language: "en"))
            try await collector.task.value("unit \(unit) to finish")
            try #require(await events.ended.wait(atLeast: unit + 1, "unit \(unit) to end"))
        }
        let peak = await renderer.peakConcurrentRenders
        let violations = await renderer.violations
        #expect(peak == 1)
        #expect(violations.isEmpty)
    }

    @Test("empty or whitespace-only text is recorded as a violation", arguments: ["", "  \n\t"])
    func emptyText(text: String) async throws {
        let renderer = MockSpeechRenderer()
        let collector = Collector(try await renderer.render(text: text, unitID: 5, voice: voice, language: "en"))
        try await collector.task.value("the empty render to end")
        let violations = await renderer.violations
        #expect(violations == [.emptyText(unitID: 5)])
    }

    @Test("a prewarm while a render runs is recorded as an overlap")
    func prewarmDuringRender() async throws {
        let events = Events()
        let renderer = MockSpeechRenderer(observer: events.observer)
        try await renderer.prewarm(voice: voice, language: "en")
        await renderer.holdStart()
        let collector = Collector(try await renderer.render(text: "Held", unitID: 0, voice: voice, language: "en"))
        try #require(await events.held.wait(atLeast: 1, "the render to park"))
        try await renderer.prewarm(voice: voice, language: "en")

        let prewarmed = await renderer.prewarmed
        let violations = await renderer.violations
        let peak = await renderer.peakConcurrentRenders
        #expect(prewarmed == [voice, voice])
        #expect(violations == [.prewarmDuringRender])
        #expect(peak == 2)

        await renderer.releaseStart()
        try await collector.task.value("the render to finish")
    }

    @Test("cancel ends a held render, returns once it has stopped, and frees the renderer")
    func cancelHeldRender() async throws {
        let events = Events()
        let renderer = MockSpeechRenderer(observer: events.observer)
        await renderer.holdStart()
        let collector = Collector(try await renderer.render(text: "Held", unitID: 0, voice: voice, language: "en"))
        try #require(await events.held.wait(atLeast: 1, "the render to park"))

        await renderer.cancel()
        #expect(events.ended.value == 1)
        let cancelCount = await renderer.cancelCount
        #expect(cancelCount == 1)
        await #expect(throws: CancellationError.self) {
            try await collector.task.value("the cancelled stream to end")
        }
        #expect(collector.chunks.value.isEmpty)

        await renderer.releaseStart()
        let next = Collector(try await renderer.render(text: "Next", unitID: 1, voice: voice, language: "en"))
        try await next.task.value("the next render to finish")
        let violations = await renderer.violations
        #expect(violations.isEmpty)
    }

    @Test("cancel with nothing in flight only counts")
    func cancelIdle() async {
        let renderer = MockSpeechRenderer()
        await renderer.cancel()
        let cancelCount = await renderer.cancelCount
        #expect(cancelCount == 1)
    }

    @Test("chunks are paced by the injected clock at the configured real-time factor")
    func pacing() async throws {
        let clock = TestClock()
        let renderer = MockSpeechRenderer(
            clock: clock, sampleRate: 10_000, secondsPerCharacter: 0.25, realTimeFactor: 0.5, chunkSeconds: 0.5
        )
        let collector = Collector(try await renderer.render(text: "Four", unitID: 0, voice: voice, language: "en"))

        try #require(await clock.waitForSleeper())
        clock.advance(by: .milliseconds(200))
        #expect(clock.sleeperCount == 1)
        #expect(collector.chunks.value.isEmpty)

        clock.advance(by: .milliseconds(50))
        let firstChunk = await collector.chunks.wait(until: { $0.count == 1 }, "the first chunk after 0.25 s")
        try #require(firstChunk)
        try #require(await clock.waitForSleeper())
        clock.advance(by: .milliseconds(250))
        try await collector.task.value("the paced render to finish")

        #expect(collector.chunks.value.map(\.samples.count) == [5_000, 5_000])
    }
}
