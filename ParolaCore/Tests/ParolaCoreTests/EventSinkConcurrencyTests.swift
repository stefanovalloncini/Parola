import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import ParolaCore

@Suite("EventSink concurrent state guard")
struct EventSinkConcurrencyTests {
    @Test("concurrent partial and energy calls never crash and leave a coherent last value")
    func concurrentCallsStayCoherent() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<256 {
                group.addTask {
                    sink.handlePartial(text: "partial-\(i % 8)")
                    sink.handleEnergy(last: i.isMultiple(of: 2) ? 0.9 : 0.01)
                }
            }
        }

        sink.handlePartial(text: "final")
        sink.handleEnergy(last: 0.9)
        sink.handleEnergy(last: 0.0)
        cont.finish()

        var lastPartial: String?
        var lastVoice: Bool?
        for await event in stream {
            switch event {
            case .partial(let text): lastPartial = text
            case .voiceActivity(let active): lastVoice = active
            default: break
            }
        }

        #expect(lastPartial == "final")
        #expect(lastVoice == false)
    }

    @Test("a value emitted once is never emitted again after a concurrent storm")
    func dedupesUnderConcurrency() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<512 {
                group.addTask { sink.handlePartial(text: "same") }
            }
        }
        cont.finish()

        var partialCount = 0
        for await event in stream {
            if case .partial = event { partialCount += 1 }
        }
        #expect(partialCount == 1)
    }
}
