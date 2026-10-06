import Foundation
import Testing
import ParolaSpeech

@Suite("FakeOutputSink")
@MainActor
struct FakeOutputSinkTests {
    @Test("records every call in order")
    func recordsCalls() throws {
        let sink = FakeOutputSink()
        let chunk = PCMChunk(unitID: 0, samples: [0, 0.5], sampleRate: 22_050)
        sink.speed = 1.5
        sink.schedule(chunk, epoch: 2, gainDB: -3)
        sink.finishUnit(0, epoch: 2, pauseAfter: 0.4)
        sink.pause(fade: true)
        try sink.resume()
        sink.stop()

        #expect(sink.calls == [
            .schedule(chunk, epoch: 2, gainDB: -3),
            .finishUnit(0, epoch: 2, pauseAfter: 0.4),
            .pause(fade: true),
            .resume,
            .stop,
        ])
        #expect(sink.scheduledChunks == [chunk])
        #expect(sink.speed == 1.5)
    }

    @Test("emitted unit-finished events reach the latest listener, and a new listener ends the old stream")
    func unitFinishedEvents() async {
        let sink = FakeOutputSink()
        let old = sink.unitFinishedEvents()
        let current = sink.unitFinishedEvents()
        sink.emitUnitFinished(epoch: 1, unitID: 0)
        sink.emitUnitFinished(epoch: 1, unitID: 1)
        _ = sink.unitFinishedEvents()

        let oldEvents = GuardedTask { await collect(old) }
        let currentEvents = GuardedTask { await collect(current) }
        let fromOld = try? await oldEvents.value("the replaced stream to finish")
        let fromCurrent = try? await currentEvents.value("the current stream to finish")
        #expect(fromOld == [])
        #expect(fromCurrent == [UnitFinished(epoch: 1, unitID: 0), UnitFinished(epoch: 1, unitID: 1)])
    }
}

private func collect(_ stream: AsyncStream<UnitFinished>) async -> [UnitFinished] {
    var events: [UnitFinished] = []
    for await event in stream { events.append(event) }
    return events
}
