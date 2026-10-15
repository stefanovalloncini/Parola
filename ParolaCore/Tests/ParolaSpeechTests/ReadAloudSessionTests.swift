import Foundation
import Testing
import ParolaCore
@testable import ParolaSpeech

@Suite("ReadAloudSession")
@MainActor
struct ReadAloudSessionTests {
    private let voice = VoiceID.appleAutomatic

    private struct Harness {
        let clock: TestClock
        let sink: FakeOutputSink
        let renderer: MockSpeechRenderer
        let renderLog: RenderLog
        let session: ReadAloudSession
        let log: SessionLog
    }

    private func harness(
        _ texts: [String],
        expandsNumbers: Bool = true,
        maxUnitChars: Int = 400,
        realTimeFactor: Double = 0,
        realTimeFactors: [Int: Double] = [:],
        startLatency: Duration = .zero,
        failAtUnit: Int? = nil,
        language: String = "en",
        clock: TestClock = TestClock(),
        sink: FakeOutputSink = FakeOutputSink(),
        renderer existing: (MockSpeechRenderer, RenderLog)? = nil
    ) -> Harness {
        let (renderer, renderLog) = existing ?? mockRenderer(
            clock: clock, expandsNumbers: expandsNumbers, maxUnitChars: maxUnitChars,
            realTimeFactor: realTimeFactor, realTimeFactors: realTimeFactors, startLatency: startLatency,
            failAtUnit: failAtUnit
        )
        let session = ReadAloudSession(
            units: units(texts), renderer: renderer, voice: voice, language: language, sink: sink, clock: clock
        )
        return Harness(
            clock: clock, sink: sink, renderer: renderer, renderLog: renderLog, session: session,
            log: SessionLog(session.events)
        )
    }

    private func mockRenderer(
        clock: TestClock,
        expandsNumbers: Bool = true,
        maxUnitChars: Int = 400,
        sampleRate: Double = 24_000,
        realTimeFactor: Double = 0,
        realTimeFactors: [Int: Double] = [:],
        startLatency: Duration = .zero,
        failAtUnit: Int? = nil
    ) -> (MockSpeechRenderer, RenderLog) {
        let renderLog = RenderLog()
        let renderer = MockSpeechRenderer(
            capabilities: SpeechRendererCapabilities(
                languages: [], expandsNumbers: expandsNumbers, usesNeuralEngine: false, nominalRTF: 0,
                maxUnitChars: maxUnitChars
            ),
            clock: clock,
            sampleRate: sampleRate,
            realTimeFactor: realTimeFactor,
            realTimeFactors: realTimeFactors,
            startLatency: startLatency,
            failAtUnit: failAtUnit,
            observer: renderLog.observer
        )
        return (renderer, renderLog)
    }

    private func units(_ texts: [String]) -> [ReadingUnit] {
        texts.enumerated().map { index, text in
            ReadingUnit(
                id: index,
                text: text,
                anchors: [.init(anchor: .summaryParagraph(index), range: NSRange(location: 0, length: text.utf16.count))],
                language: nil,
                pauseAfter: index == texts.count - 1 ? 0 : 0.25
            )
        }
    }

    /// At the mock's 0.06 s a character: 100 characters are 6 s of audio, 25 are 1.5 s, 10 are 0.6 s.
    private func sentence(_ characters: Int, _ letter: Character = "x") -> String {
        String(repeating: letter, count: characters)
    }

    private func complete(_ harness: Harness, startsTotal: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try #require(harness.sink.completeNextUnit() != nil, sourceLocation: sourceLocation)
        try #require(await harness.log.waitForStarts(startsTotal, sourceLocation: sourceLocation), sourceLocation: sourceLocation)
        await harness.session.settle()
    }

    private func drive(_ clock: TestClock, sleeps: Int, of step: Duration) async {
        for _ in 0..<sleeps {
            await clock.waitForSleeper()
            clock.advance(by: step)
        }
    }

    private func expectSingleFlight(_ renderer: MockSpeechRenderer, sourceLocation: SourceLocation = #_sourceLocation) async {
        let peak = await renderer.peakConcurrentRenders
        let violations = await renderer.violations
        #expect(peak == 1, sourceLocation: sourceLocation)
        #expect(violations.isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: - Playback order

    @Test("play announces the first unit, subscribes before scheduling, and starts the output")
    func playStarts() async {
        let h = harness([sentence(100), sentence(100), sentence(100)])
        await h.session.play()
        await h.session.settle()

        #expect(h.log.started == [0])
        #expect(h.sink.calls.first == .subscribe)
        #expect(h.sink.calls.contains(.resume))
        #expect(h.sink.schedulesBeforeSubscribing == 0)
        #expect(h.sink.finishedUnits == [0, 1, 2])
        #expect(h.sink.scheduledChunks.allSatisfy { $0.sampleRate == 24_000 })
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    @Test("a unit starts only once the sink reports the one before it finished, and the end stops the sink")
    func startsFollowFinishEvents() async throws {
        let h = harness([sentence(100), sentence(100), sentence(100)])
        await h.session.play()
        await h.session.settle()
        #expect(h.log.started == [0])

        try await complete(h, startsTotal: 2)
        #expect(h.log.started == [0, 1])
        try await complete(h, startsTotal: 3)
        #expect(h.log.started == [0, 1, 2])

        try #require(h.sink.completeNextUnit() != nil)
        try #require(await h.log.waitForEnd())
        #expect(h.log.events.value.last == .finished)
        #expect(h.sink.calls.last == .stop)
    }

    @Test("each unit's start carries that unit's anchors")
    func anchorsTravel() async throws {
        let texts = [sentence(20), sentence(30)]
        let h = harness(texts)
        await h.session.play()
        await h.session.settle()
        try await complete(h, startsTotal: 2)

        let expected = units(texts).map { ReadAloudSessionEvent.unitStarted(index: $0.id, anchors: $0.anchors) }
        #expect(h.log.events.value == expected)
        await h.session.stop()
    }

    // MARK: - Look-ahead

    @Test("look-ahead keeps two units ready when they hold ten seconds")
    func lookAheadTwoUnits() async throws {
        let h = harness(Array(repeating: sentence(100), count: 6))
        await h.session.play()
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2])

        try await complete(h, startsTotal: 2)
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2, 3])
        #expect(h.sink.finishedUnits == [0, 1, 2, 3])
        await h.session.stop()
    }

    @Test("look-ahead renders past two units until ten seconds are ready")
    func lookAheadTenSeconds() async {
        let h = harness(Array(repeating: sentence(10), count: 25))
        await h.session.play()
        await h.session.settle()

        #expect(await h.renderer.rendered.map(\.unitID) == Array(0...17))
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    // MARK: - Text for the renderer

    @Test("a unit with nothing to say never reaches the renderer, plays its pause, and keeps later starts aligned")
    func emptyUnitKeepsAlignment() async throws {
        let h = harness(["First one.", "🎉🎉", "Third one."], expandsNumbers: false)
        await h.session.play()
        await h.session.settle()

        #expect(await h.renderer.rendered.map(\.unitID) == [0, 2])
        #expect(!h.sink.scheduledChunks.contains { $0.unitID == 1 })
        #expect(h.sink.calls.contains(.finishUnit(1, epoch: 0, pauseAfter: 0.25)))
        #expect(h.sink.finishedUnits == [0, 1, 2])

        try await complete(h, startsTotal: 2)
        try await complete(h, startsTotal: 3)
        #expect(h.log.started == [0, 1, 2])
        let violations = await h.renderer.violations
        #expect(violations.isEmpty)
        await h.session.stop()
    }

    @Test("a long Chinese run and a long URL reach the renderer in pieces of at most 70, as one unit")
    func renderTimeSplit() async {
        let chinese = String(String(repeating: "这是一个没有标点的长句子", count: 84).prefix(1_000))
        let url = "https://example.com/" + String(repeating: "abcdefghij", count: 28)
        let h = harness([chinese, url], maxUnitChars: 70, language: "zh")
        await h.session.play()
        await h.session.settle()

        let rendered = await h.renderer.rendered
        let first = rendered.filter { $0.unitID == 0 }.map(\.text)
        let second = rendered.filter { $0.unitID == 1 }.map(\.text)
        #expect(first.count == 15)
        #expect(first.joined() == chinese)
        #expect(second.joined() == url)
        #expect(rendered.allSatisfy { $0.text.count <= 70 })
        #expect(h.sink.finishedUnits == [0, 1])
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    // MARK: - Skip and back

    @Test("Next while playing stops the sink, schedules the next unit, then resumes")
    func nextWhilePlaying() async {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.session.play()
        await h.session.settle()
        let mark = h.sink.calls.count

        await h.session.next()
        let after = Array(h.sink.calls[mark...])
        let firstFinish = after.firstIndex(of: .finishUnit(1, epoch: 1, pauseAfter: 0.25))
        let resume = after.firstIndex(of: .resume)
        #expect(after.first == .stop)
        #expect(firstFinish != nil)
        #expect(resume != nil)
        #expect((firstFinish ?? .max) < (resume ?? .min))
        #expect(h.log.started == [0, 1])
        await h.session.stop()
    }

    @Test("Next while paused moves and schedules but leaves the output idle")
    func nextWhilePaused() async {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.session.play()
        await h.session.settle()
        await h.session.pause(fade: true)
        let mark = h.sink.calls.count

        await h.session.next()
        await h.session.settle()
        let after = Array(h.sink.calls[mark...])
        #expect(after.first == .stop)
        #expect(after.contains(.finishUnit(1, epoch: 1, pauseAfter: 0.25)))
        #expect(!after.contains(.resume))
        #expect(h.log.started == [0, 1])
        await h.session.stop()
    }

    @Test("Next on the last unit finishes the reading")
    func nextPastTheEnd() async throws {
        let h = harness([sentence(20)])
        await h.session.play()
        await h.session.settle()
        await h.session.next()

        try #require(await h.log.waitForEnd())
        #expect(h.log.events.value.last == .finished)
        #expect(h.sink.calls.last == .stop)
    }

    @Test("Previous restarts the unit after more than 1.5 s of it has played, else goes back; paused time doesn't count")
    func previousRule() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.session.play()
        await h.session.settle()
        try await complete(h, startsTotal: 2)

        h.clock.advance(by: .seconds(2))
        await h.session.previous()
        #expect(h.log.started == [0, 1, 1])

        h.clock.advance(by: .seconds(1))
        await h.session.previous()
        #expect(h.log.started == [0, 1, 1, 0])

        try await complete(h, startsTotal: 5)
        h.clock.advance(by: .seconds(1))
        await h.session.pause(fade: false)
        h.clock.advance(by: .seconds(10))
        await h.session.resume()
        h.clock.advance(by: .milliseconds(400))
        await h.session.previous()
        #expect(h.log.started == [0, 1, 1, 0, 1, 0])

        try await complete(h, startsTotal: 7)
        h.clock.advance(by: .seconds(1))
        await h.session.pause(fade: false)
        await h.session.resume()
        h.clock.advance(by: .milliseconds(600))
        await h.session.previous()
        #expect(h.log.started == [0, 1, 1, 0, 1, 0, 1, 1])

        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2, 3])
        await h.session.stop()
    }

    @Test("Previous replays the last two played units from memory and drops older audio")
    func previousCache() async throws {
        let h = harness(Array(repeating: sentence(100), count: 8))
        await h.session.play()
        await h.session.settle()
        for starts in 2...5 {
            try await complete(h, startsTotal: starts)
        }
        #expect(await h.session.cachedUnits == [2, 3, 4, 5, 6])

        await h.session.previous()
        await h.session.previous()
        await h.session.settle()
        #expect(await h.renderer.rendered.filter { $0.unitID == 2 || $0.unitID == 3 }.count == 2)

        await h.session.previous()
        await h.session.settle()
        #expect(h.log.started == [0, 1, 2, 3, 4, 3, 2, 1])
        #expect(await h.renderer.rendered.filter { $0.unitID == 1 }.count == 2)
        await h.session.stop()
    }

    @Test("a completion from an epoch the reading has left is ignored")
    func staleCompletionIgnored() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.session.play()
        await h.session.settle()
        await h.session.next()
        let generation = try #require(h.sink.pending.first?.generation)

        let delivered = h.sink.deliver(FakeOutputSink.Completion(
            generation: generation, finished: UnitFinished(epoch: 0, unitID: 1)
        ))
        h.sink.simulateOutputChange()
        try #require(await h.log.wait(for: .interrupted))

        #expect(delivered)
        #expect(h.log.started == [0, 1])
        await h.session.stop()
    }

    // MARK: - Pause, resume, stop

    @Test("pause holds new renders until resume")
    func pauseStopsRendering() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.renderer.holdStart()
        await h.session.play()
        try #require(await h.renderLog.wait(for: .held(unitID: 0)))

        await h.session.pause(fade: true)
        await h.renderer.releaseStart()
        await h.session.settle()
        #expect(h.sink.calls.contains(.pause(fade: true)))
        #expect(await h.renderer.rendered.map(\.unitID) == [0])

        let resumes = h.sink.calls.filter { $0 == .resume }.count
        await h.session.resume()
        await h.session.settle()
        #expect(h.sink.calls.filter { $0 == .resume }.count == resumes + 1)
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2])
        await h.session.stop()
    }

    @Test("stop cancels the render in flight and waits for it, stops the sink, and ends without finished")
    func stopCancels() async throws {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.renderer.holdStart()
        await h.session.play()
        try #require(await h.renderLog.wait(for: .held(unitID: 0)))

        await h.session.stop()
        #expect(await h.renderer.cancelCount == 1)
        #expect(h.renderLog.events.value.contains(.ended(unitID: 0)))
        #expect(h.sink.calls.last == .stop)
        try #require(await h.log.waitForEnd())
        #expect(!h.log.events.value.contains(.finished))
        #expect(h.sink.pending.isEmpty)
    }

    @Test("speed goes to the sink and nothing renders again")
    func speedForwards() async {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.session.play()
        await h.session.settle()
        let rendered = await h.renderer.rendered

        await h.session.setSpeed(1.5)
        await h.session.settle()
        #expect(h.sink.calls.contains(.setSpeed(1.5)))
        #expect(h.sink.speed == 1.5)
        #expect(await h.renderer.rendered == rendered)
        await h.session.stop()
    }

    // MARK: - Output changes

    @Test("when the sink ends the stream the reading pauses itself, and resume subscribes again and replays the unit")
    func outputChange() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.session.play()
        await h.session.settle()
        try await complete(h, startsTotal: 2)

        h.sink.simulateOutputChange()
        try #require(await h.log.wait(for: .interrupted))
        let mark = h.sink.calls.count
        await h.session.settle()
        #expect(h.sink.calls.count == mark)

        await h.session.resume()
        let after = Array(h.sink.calls[mark...])
        #expect(after.first == .subscribe)
        #expect(after.contains(.finishUnit(1, epoch: 1, pauseAfter: 0.25)))
        #expect(after.last == .resume)
        #expect(h.sink.schedulesBeforeSubscribing == 0)
        #expect(h.log.started == [0, 1, 1])

        try await complete(h, startsTotal: 4)
        #expect(h.log.started == [0, 1, 1, 2])
        await h.session.stop()
    }

    @Test("stopping a reading the sink already left keeps the reading that took the sink over")
    func supersededStopKeepsNewReading() async throws {
        let clock = TestClock()
        let sink = FakeOutputSink()
        let (renderer, _) = mockRenderer(clock: clock)
        let first = ReadAloudSession(
            units: units([sentence(100), sentence(100), sentence(100)]), renderer: renderer, voice: voice,
            language: "en", sink: sink, clock: clock
        )
        let firstLog = SessionLog(first.events)
        await first.play()
        await first.settle()
        sink.simulateOutputChange()
        try #require(await firstLog.wait(for: .interrupted))

        let second = ReadAloudSession(
            units: units([sentence(100), sentence(100), sentence(100)]), renderer: renderer, voice: voice,
            language: "en", sink: sink, clock: clock
        )
        await second.play()
        await second.settle()
        let pending = sink.pending.count
        let stops = sink.calls.filter { $0 == .stop }.count
        await first.stop()

        #expect(pending == 3)
        #expect(sink.pending.count == pending)
        #expect(sink.calls.filter { $0 == .stop }.count == stops)
        await second.stop()
    }

    @Test("an output change while paused also waits for resume")
    func outputChangeWhilePaused() async throws {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.session.play()
        await h.session.settle()
        await h.session.pause(fade: true)

        h.sink.simulateOutputChange()
        try #require(await h.log.wait(for: .interrupted))
        let mark = h.sink.calls.count
        await h.session.next()
        await h.session.settle()
        #expect(h.sink.calls.count == mark)
        #expect(h.log.started == [0, 1])

        await h.session.resume()
        let after = Array(h.sink.calls[mark...])
        #expect(after.first == .subscribe)
        #expect(after.last == .resume)
        #expect(h.log.started == [0, 1, 1])
        await h.session.stop()
    }

    // MARK: - Single flight

    @Test("Next cancels a render that is no longer needed and waits for its end")
    func skipCancelsUnneededRender() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4))
        await h.renderer.holdStart()
        await h.session.play()
        try #require(await h.renderLog.wait(for: .held(unitID: 0)))

        await h.session.next()
        #expect(await h.renderer.cancelCount == 1)
        #expect(h.renderLog.events.value.contains(.ended(unitID: 0)))

        await h.renderer.releaseStart()
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2, 3])
        #expect(h.sink.finishedUnits == [1, 2, 3])
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    @Test("Next keeps a render in flight when it is the unit now needed")
    func skipKeepsNeededRender() async throws {
        let h = harness(Array(repeating: sentence(25), count: 3), realTimeFactor: 1)
        await h.session.play()
        await drive(h.clock, sleeps: 6, of: .milliseconds(250))
        await drive(h.clock, sleeps: 1, of: .milliseconds(250))

        await h.session.next()
        await drive(h.clock, sleeps: 5, of: .milliseconds(250))
        try #require(await h.renderLog.wait(for: .ended(unitID: 1)))

        #expect(await h.renderer.cancelCount == 0)
        #expect(await h.renderer.rendered.map(\.unitID).prefix(2) == [0, 1])
        await h.session.stop()
        await expectSingleFlight(h.renderer)
    }

    @Test("a new reading after stop never overlaps the stopped one's render")
    func stopThenPlay() async throws {
        let clock = TestClock()
        let sink = FakeOutputSink()
        let shared = mockRenderer(clock: clock)
        let first = harness(Array(repeating: sentence(100), count: 3), clock: clock, sink: sink, renderer: shared)
        await first.renderer.holdStart()
        await first.session.play()
        try #require(await first.renderLog.wait(for: .held(unitID: 0)))

        await first.session.stop()
        await first.renderer.releaseStart()
        let second = harness(Array(repeating: sentence(100), count: 3), clock: clock, sink: sink, renderer: shared)
        await second.session.play()
        await second.session.settle()

        #expect(await second.renderer.rendered.map(\.unitID) == [0, 0, 1, 2])
        #expect(sink.finishedUnits == [0, 1, 2])
        await expectSingleFlight(second.renderer)
        await second.session.stop()
    }

    @Test("a prewarm asked for during a render runs after it, before the next render")
    func prewarmDuringRender() async throws {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.renderer.holdStart()
        await h.session.play()
        try #require(await h.renderLog.wait(for: .held(unitID: 0)))

        let session = h.session
        let prewarm = GuardedTask { try await session.prewarm() }
        await h.session.laneQueued(1)
        await h.renderer.releaseStart()
        try await prewarm.value("the prewarm to run")
        await h.session.settle()

        let events = h.renderLog.events.value
        let prewarmEnd = try #require(events.firstIndex(of: .prewarmEnded))
        let firstEnd = try #require(events.firstIndex(of: .ended(unitID: 0)))
        let secondStart = try #require(events.firstIndex(of: .started(unitID: 1)))
        #expect(firstEnd < prewarmEnd)
        #expect(prewarmEnd < secondStart)
        #expect(await h.renderer.prewarmed == [voice])
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    @Test("play during a prewarm renders only once the prewarm ends")
    func playDuringPrewarm() async throws {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.renderer.holdPrewarm()
        let session = h.session
        let prewarm = GuardedTask { try await session.prewarm() }
        try #require(await h.renderLog.wait(for: .prewarmHeld))

        await h.session.play()
        await h.renderer.releasePrewarm()
        try await prewarm.value("the prewarm to finish")
        await h.session.settle()

        let events = h.renderLog.events.value
        let prewarmEnd = try #require(events.firstIndex(of: .prewarmEnded))
        let firstStart = try #require(events.firstIndex(of: .started(unitID: 0)))
        #expect(prewarmEnd < firstStart)
        await expectSingleFlight(h.renderer)
        await h.session.stop()
    }

    // MARK: - Slow renderers

    private func startRenderingAhead(_ h: Harness, afterUnit: Int, sleeps: Int, of step: Duration) async throws {
        await drive(h.clock, sleeps: sleeps, of: step)
        try #require(await h.renderLog.wait(for: .started(unitID: afterUnit + 1)))
        await h.session.settlePump()
    }

    @Test("a renderer slower than playback finishes the unit it is waited on for, waits, and continueReading goes on")
    func slowRendererWaits() async throws {
        let h = harness(Array(repeating: sentence(25), count: 4), realTimeFactor: 2)
        await h.session.play()
        try await startRenderingAhead(h, afterUnit: 0, sleeps: 6, of: .milliseconds(500))
        try #require(h.sink.completeNextUnit() != nil)
        try #require(await h.log.waitForStarts(2))

        await drive(h.clock, sleeps: 6, of: .milliseconds(500))
        try #require(await h.log.wait(for: .waiting(.slow)))
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1])
        #expect(h.sink.finishedUnits == [0, 1])

        try await complete(h, startsTotal: 3)
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1])

        await h.session.continueReading()
        await drive(h.clock, sleeps: 6, of: .milliseconds(500))
        try #require(await h.log.wait(for: .waiting(.slow), count: 2))
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2])
        await h.session.stop()
    }

    @Test("the wait depends on render speed times playback speed", arguments: [(1.0, false), (1.5, true)])
    func slowDependsOnSpeed(speed: Double, waits: Bool) async throws {
        let h = harness(Array(repeating: sentence(25), count: 4), realTimeFactor: 0.8)
        await h.session.setSpeed(speed)
        await h.session.play()
        try await startRenderingAhead(h, afterUnit: 0, sleeps: 6, of: .milliseconds(200))
        try #require(h.sink.completeNextUnit() != nil)
        try #require(await h.log.waitForStarts(2))
        await drive(h.clock, sleeps: 6, of: .milliseconds(200))

        if waits {
            try #require(await h.log.wait(for: .waiting(.slow)))
            await h.session.settle()
            #expect(await h.renderer.rendered.map(\.unitID) == [0, 1])
        } else {
            try #require(await h.renderLog.wait(for: .started(unitID: 2)))
            #expect(!h.log.events.value.contains(.waiting(.slow)))
        }
        await h.session.stop()
    }

    @Test("a fixed latency on a short first unit is not a slow voice")
    func firstUnitLatencyDoesNotHold() async throws {
        let h = harness(
            [sentence(10), sentence(100), sentence(100), sentence(100)], startLatency: .seconds(1)
        )
        await h.session.play()
        await drive(h.clock, sleeps: 1, of: .seconds(1))
        try #require(await h.renderLog.wait(for: .started(unitID: 1)))
        await drive(h.clock, sleeps: 1, of: .seconds(1))
        try #require(await h.renderLog.wait(for: .started(unitID: 2)))
        #expect(!h.log.events.value.contains(.waiting(.slow)))
        await h.session.stop()
    }

    @Test("units rendered ahead of playback never hold the reading, however slow they are")
    func lookAheadNeverHolds() async throws {
        let h = harness(
            Array(repeating: sentence(25), count: 4), realTimeFactors: [0: 0, 1: 2, 2: 2, 3: 2]
        )
        await h.session.play()
        await drive(h.clock, sleeps: 18, of: .milliseconds(500))
        try #require(await h.renderLog.wait(for: .ended(unitID: 3)))
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2, 3])
        #expect(!h.log.events.value.contains(.waiting(.slow)))
        await h.session.stop()
    }

    // MARK: - Voice switch

    @Test("a voice switch while playing waits for the unit boundary, then renders the rest for the new renderer")
    func switchAtBoundary() async throws {
        let clock = TestClock()
        let h = harness(["I have 3 cats.", "She has 12 dogs.", "We saw 7 birds."], expandsNumbers: false, clock: clock)
        let (other, otherLog) = mockRenderer(clock: clock, expandsNumbers: true, sampleRate: 16_000)
        await h.session.play()
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.text) == ["I have three cats.", "She has twelve dogs.", "We saw seven birds."])
        let mark = h.sink.calls.count

        await h.session.switchRenderer(other, voice: voice, fromUnit: 1)
        await h.session.settle()
        #expect(h.sink.calls.count == mark)
        #expect(await other.rendered.isEmpty)

        try await complete(h, startsTotal: 2)
        #expect(await other.rendered.map(\.text) == ["She has 12 dogs.", "We saw 7 birds."])
        let after = Array(h.sink.calls[mark...])
        let chunks = after.compactMap { call -> PCMChunk? in
            guard case .schedule(let chunk, _, _) = call else { return nil }
            return chunk
        }
        #expect(after.first == .stop)
        #expect(after.contains(.finishUnit(1, epoch: 1, pauseAfter: 0.25)))
        #expect(after.contains(.resume))
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.sampleRate == 16_000 })
        #expect(h.log.started == [0, 1])
        #expect(otherLog.events.value.contains(.ended(unitID: 2)))
        await expectSingleFlight(h.renderer)
        await expectSingleFlight(other)
        await h.session.stop()
    }

    @Test("a voice switch while paused takes effect at once and renders for the new renderer on resume")
    func switchWhilePaused() async throws {
        let clock = TestClock()
        let h = harness(["I have 3 cats.", "She has 12 dogs."], expandsNumbers: false, clock: clock)
        let (other, _) = mockRenderer(clock: clock, expandsNumbers: true, sampleRate: 16_000)
        await h.session.play()
        await h.session.settle()
        await h.session.pause(fade: true)
        let mark = h.sink.calls.count

        await h.session.switchRenderer(other, voice: voice, fromUnit: 0)
        await h.session.settle()
        #expect(Array(h.sink.calls[mark...]) == [.stop])
        #expect(await other.rendered.isEmpty)
        #expect(h.log.started == [0, 0])

        await h.session.resume()
        await h.session.settle()
        let after = Array(h.sink.calls[mark...])
        #expect(after.contains(.finishUnit(0, epoch: 1, pauseAfter: 0.25)))
        #expect(after.contains(.resume))
        #expect(await other.rendered.map(\.text) == ["I have 3 cats.", "She has 12 dogs."])
        await h.session.stop()
    }

    // MARK: - Blocking and failure

    @Test("while blocked no unit starts scheduling, and unblocking catches up")
    func blockedHoldsScheduling() async throws {
        let h = harness(Array(repeating: sentence(100), count: 6))
        await h.session.play()
        await h.session.settle()
        #expect(h.sink.finishedUnits == [0, 1, 2])

        await h.session.setBlocked(true)
        try await complete(h, startsTotal: 2)
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2, 3])
        #expect(h.sink.finishedUnits == [0, 1, 2])

        await h.session.setBlocked(false)
        await h.session.settle()
        #expect(h.sink.finishedUnits == [0, 1, 2, 3])
        await h.session.stop()
    }

    @Test("a reading blocked from the start renders but schedules nothing")
    func blockedFromTheStart() async {
        let h = harness(Array(repeating: sentence(100), count: 3))
        await h.session.setBlocked(true)
        await h.session.play()
        await h.session.settle()

        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2])
        #expect(h.sink.scheduledChunks.isEmpty)
        #expect(h.sink.finishedUnits.isEmpty)
        await h.session.stop()
    }

    @Test("a renderer failure on the unit playing now fails the reading and stops the sink")
    func failureNow() async throws {
        let h = harness(Array(repeating: sentence(100), count: 3), failAtUnit: 0)
        await h.session.play()

        try #require(await h.log.waitForEnd())
        #expect(h.log.events.value.last == .failed(String(describing: MockSpeechRenderer.Failure(unitID: 0))))
        #expect(h.sink.calls.last == .stop)
    }

    @Test("a failure further ahead lets the units before it play, then fails where it happened")
    func failureAhead() async throws {
        let h = harness(Array(repeating: sentence(100), count: 4), failAtUnit: 2)
        await h.session.play()
        await h.session.settle()
        #expect(await h.renderer.rendered.map(\.unitID) == [0, 1, 2])
        #expect(h.log.started == [0])

        try await complete(h, startsTotal: 2)
        try #require(h.sink.completeNextUnit() != nil)
        try #require(await h.log.waitForEnd())
        #expect(h.log.started == [0, 1])
        #expect(h.log.events.value.last == .failed(String(describing: MockSpeechRenderer.Failure(unitID: 2))))
        #expect(h.sink.calls.last == .stop)
    }
}

final class SessionLog: Sendable {
    let events = Awaitable<[ReadAloudSessionEvent]>([])
    let ended = TestSignal()

    init(_ stream: AsyncStream<ReadAloudSessionEvent>) {
        let events = events
        let ended = ended
        Task {
            for await event in stream {
                events.update { $0.append(event) }
            }
            ended.fire()
        }
    }

    var started: [Int] {
        events.value.compactMap(\.startedIndex)
    }

    @discardableResult
    func waitForStarts(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await events.wait(
            until: { $0.compactMap(\.startedIndex).count >= count }, "\(count) unit starts", sourceLocation: sourceLocation
        )
    }

    @discardableResult
    func wait(for event: ReadAloudSessionEvent, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await events.wait(
            until: { $0.filter { $0 == event }.count >= count }, "\(count) × \(event)", sourceLocation: sourceLocation
        )
    }

    @discardableResult
    func waitForEnd(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await ended.wait("the session's events to end", sourceLocation: sourceLocation)
    }
}

final class RenderLog: Sendable {
    let events = Awaitable<[MockSpeechRenderer.Event]>([])

    var observer: MockSpeechRenderer.Observer {
        { [events] event in events.update { $0.append(event) } }
    }

    @discardableResult
    func wait(for event: MockSpeechRenderer.Event, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await events.wait(until: { $0.contains(event) }, "the renderer event \(event)", sourceLocation: sourceLocation)
    }
}

extension ReadAloudSessionEvent {
    var startedIndex: Int? {
        guard case .unitStarted(let index, _) = self else { return nil }
        return index
    }
}

extension FakeOutputSink {
    var finishedUnits: [Int] {
        calls.compactMap { call in
            guard case .finishUnit(let unitID, _, _) = call else { return nil }
            return unitID
        }
    }
}
