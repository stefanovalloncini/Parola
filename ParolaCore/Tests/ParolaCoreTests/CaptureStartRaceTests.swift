import Foundation
import Testing
import os
@preconcurrency import WhisperKit
@testable import ParolaCore

@Suite("A stop while the capture starts")
struct CaptureStartRaceTests {
    private struct Counts {
        var stops = 0
        var interrupts = 0
        var stopsBeforeStartReturned = 0
        var startReturned = false
    }

    private func makeLoop(gate: UninterruptibleGate, counts: OSAllocatedUnfairLock<Counts>) -> StreamingRealtimeLoop {
        StreamingRealtimeLoop(
            configuration: .init(),
            decodingOptions: DecodingOptions(),
            dependencies: .init(
                requestPermission: { true },
                startCapture: { _ in
                    await gate.wait()
                    counts.withLock { $0.startReturned = true }
                },
                stopCapture: {
                    counts.withLock {
                        $0.stops += 1
                        if !$0.startReturned { $0.stopsBeforeStartReturned += 1 }
                    }
                },
                interruptStart: { counts.withLock { $0.interrupts += 1 } },
                transcribe: { _, _, _ in
                    TranscriptionResult(text: "", segments: [], language: "en", timings: TranscriptionTimings())
                },
                tick: { try await Task.sleep(nanoseconds: 1_000_000) }
            ),
            onPartial: { _ in },
            onEnergy: { _ in },
            onConfirmed: { _ in }
        )
    }

    @Test("it interrupts the start instead of stopping the capture under it, then stops what came up")
    func stopWaitsForTheStart() async throws {
        let gate = UninterruptibleGate()
        let counts = OSAllocatedUnfairLock(initialState: Counts())
        let loop = makeLoop(gate: gate, counts: counts)
        let running = GuardedTask { await loop.run() }
        await gate.arrivals.wait(atLeast: 1, "the capture to begin starting")

        await loop.stop()
        #expect(counts.withLock { $0.interrupts } == 1)
        #expect(counts.withLock { $0.stopsBeforeStartReturned } == 0, "the capture is not stopped while it is still starting")

        gate.open()
        let outcome = try #require(try await running.value("the run to end"))
        guard case .stopped = outcome else {
            Issue.record("expected .stopped, got \(outcome)")
            return
        }
        #expect(counts.withLock { $0.stops } == 1, "whatever came up is stopped once")
    }
}
