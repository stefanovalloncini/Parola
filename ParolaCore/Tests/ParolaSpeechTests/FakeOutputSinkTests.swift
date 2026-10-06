import Foundation
import Testing
import ParolaSpeech

@Suite("FakeOutputSink")
@MainActor
struct FakeOutputSinkTests {
    private actor SessionShapedCaller {
        let sink: any ReadAloudOutputSink

        init(sink: any ReadAloudOutputSink) {
            self.sink = sink
        }

        func readOneUnit(_ chunk: PCMChunk) async throws -> (events: AsyncStream<UnitFinished>, speed: Double) {
            let events = await sink.unitFinishedEvents()
            await sink.setSpeed(1.5)
            await sink.schedule(chunk, epoch: 0, gainDB: -3)
            await sink.finishUnit(chunk.unitID, epoch: 0, pauseAfter: 0.4)
            await sink.pause(fade: true)
            try await sink.resume()
            let speed = await sink.speed
            return (events, speed)
        }

        func stop() async {
            await sink.stop()
        }
    }

    @Test("a caller on another actor drives the sink, and every call is recorded in order")
    func callsFromAnActor() async throws {
        let sink = FakeOutputSink()
        let caller = SessionShapedCaller(sink: sink)
        let chunk = PCMChunk(unitID: 0, samples: [0, 0.5], sampleRate: 22_050)
        let (events, speed) = try await caller.readOneUnit(chunk)
        sink.completeNextUnit()
        await caller.stop()
        _ = sink.unitFinishedEvents()

        let received = await collect(events, "the first listener's events")
        #expect(speed == 1.5)
        #expect(received == [UnitFinished(epoch: 0, unitID: 0)])
        #expect(sink.calls == [
            .subscribe,
            .setSpeed(1.5),
            .schedule(chunk, epoch: 0, gainDB: -3),
            .finishUnit(0, epoch: 0, pauseAfter: 0.4),
            .pause(fade: true),
            .resume,
            .stop,
            .subscribe,
        ])
        #expect(sink.scheduledChunks == [chunk])
        #expect(sink.schedulesBeforeSubscribing == 0)
    }

    @Test("a completion from before a new subscription is dropped, even with a matching epoch")
    func staleCompletionAfterResubscribe() async {
        let sink = FakeOutputSink()
        let first = sink.unitFinishedEvents()
        sink.finishUnit(0, epoch: 0, pauseAfter: 0)
        let late = sink.pending

        let second = sink.unitFinishedEvents()
        sink.finishUnit(0, epoch: 0, pauseAfter: 0)
        let lateDelivered = late.map { sink.deliver($0) }
        let next = sink.completeNextUnit()
        _ = sink.unitFinishedEvents()

        let fromFirst = await collect(first, "the replaced stream to finish")
        let fromSecond = await collect(second, "the second stream to finish")
        #expect(lateDelivered == [false])
        #expect(next == UnitFinished(epoch: 0, unitID: 0))
        #expect(fromFirst == [])
        #expect(fromSecond == [UnitFinished(epoch: 0, unitID: 0)])
    }

    @Test("stop drops every pending completion but keeps the listener")
    func stopDropsPending() async {
        let sink = FakeOutputSink()
        let events = sink.unitFinishedEvents()
        sink.finishUnit(0, epoch: 0, pauseAfter: 0.2)
        sink.finishUnit(1, epoch: 0, pauseAfter: 0.2)
        let beforeStop = sink.pending

        sink.stop()
        let pendingAfterStop = sink.pending
        let lateDelivered = beforeStop.map { sink.deliver($0) }
        sink.finishUnit(1, epoch: 1, pauseAfter: 0.2)
        let next = sink.completeNextUnit()
        _ = sink.unitFinishedEvents()

        let received = await collect(events, "the stream to finish")
        #expect(pendingAfterStop.isEmpty)
        #expect(lateDelivered == [false, false])
        #expect(next == UnitFinished(epoch: 1, unitID: 1))
        #expect(received == [UnitFinished(epoch: 1, unitID: 1)])
    }

    @Test("subscribing again finishes the previous stream")
    func resubscribeFinishesOldStream() async {
        let sink = FakeOutputSink()
        let old = sink.unitFinishedEvents()
        let current = sink.unitFinishedEvents()
        sink.finishUnit(0, epoch: 1, pauseAfter: 0)
        sink.finishUnit(1, epoch: 1, pauseAfter: 0)
        sink.completeNextUnit()
        sink.completeNextUnit()
        _ = sink.unitFinishedEvents()

        let fromOld = await collect(old, "the replaced stream to finish")
        let fromCurrent = await collect(current, "the current stream to finish")
        #expect(fromOld == [])
        #expect(fromCurrent == [UnitFinished(epoch: 1, unitID: 0), UnitFinished(epoch: 1, unitID: 1)])
    }

    @Test("scheduling before subscribing is counted")
    func scheduleBeforeSubscribing() {
        let sink = FakeOutputSink()
        sink.schedule(PCMChunk(unitID: 0, samples: [0], sampleRate: 24_000), epoch: 0, gainDB: 0)
        sink.finishUnit(0, epoch: 0, pauseAfter: 0)
        #expect(sink.schedulesBeforeSubscribing == 2)
    }
}

private func collect(_ stream: AsyncStream<UnitFinished>, _ description: String) async -> [UnitFinished]? {
    let task = GuardedTask {
        var events: [UnitFinished] = []
        for await event in stream { events.append(event) }
        return events
    }
    return try? await task.value(description)
}
