import Foundation
import Testing
import os
@preconcurrency import WhisperKit
@testable import ParolaCore

private let sampleRate = 16_000

private final class FakeCapture: Sendable {
    private let state = OSAllocatedUnfairLock<(callback: (@Sendable ([Float]) -> Void)?, stopped: Bool)>(
        initialState: (nil, false)
    )

    func install(_ callback: @escaping @Sendable ([Float]) -> Void) {
        state.withLock { $0.callback = callback }
    }

    func markStopped() {
        state.withLock { $0.stopped = true }
    }

    var installed: Bool { state.withLock { $0.callback != nil } }
    var stopped: Bool { state.withLock { $0.stopped } }

    func push(_ samples: [Float]) {
        let callback = state.withLock { $0.callback }
        callback?(samples)
    }

    func push(seconds: Double, value: Float) {
        push([Float](repeating: value, count: Int(seconds * Double(sampleRate))))
    }

    func pushRamp(seconds: Double) {
        let count = Int(seconds * Double(sampleRate))
        push((0..<count).map { Float($0) / Float(count) })
    }

    func pushBuffers(count: Int, secondsEach: Double, value: Float) {
        let samplesEach = Int(secondsEach * Double(sampleRate))
        for _ in 0..<count {
            push([Float](repeating: value, count: samplesEach))
        }
    }
}

private actor TranscribeScript {
    struct Call {
        var sampleCount: Int
        var clip: [Float]
        var firstSample: Float
    }

    private var queued: [[TranscriptionSegment]]
    private let failure: (any Error)?
    private(set) var calls: [Call] = []

    init(responses: [[TranscriptionSegment]], failure: (any Error)? = nil) {
        self.queued = responses
        self.failure = failure
    }

    func invoke(_ samples: [Float], _ options: DecodingOptions) throws -> TranscriptionResult {
        calls.append(Call(
            sampleCount: samples.count,
            clip: options.clipTimestamps,
            firstSample: samples.first ?? .nan
        ))
        if let failure { throw failure }
        let segments = queued.isEmpty ? [] : queued.removeFirst()
        return TranscriptionResult(text: "", segments: segments, language: "en", timings: TranscriptionTimings())
    }

    var callCount: Int { calls.count }
}

private final class EventRecorder: Sendable {
    private let state = OSAllocatedUnfairLock<(partials: [String], batches: [ConfirmedAudioBatch])>(
        initialState: ([], [])
    )

    func recordPartial(_ text: String) {
        state.withLock { $0.partials.append(text) }
    }

    func recordBatch(_ batch: ConfirmedAudioBatch) {
        state.withLock { $0.batches.append(batch) }
    }

    var partials: [String] { state.withLock { $0.partials } }
    var batches: [ConfirmedAudioBatch] { state.withLock { $0.batches } }
}

private struct ScriptError: Error {}

private func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text)
}

private func eventually(
    timeoutMs: Int = 5000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<(timeoutMs) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

private func makeLoop(
    responses: [[TranscriptionSegment]],
    failure: (any Error)? = nil,
    useVAD: Bool = false,
    wantsConfirmedAudio: Bool = false,
    permissionGranted: Bool = true
) -> (loop: StreamingRealtimeLoop, capture: FakeCapture, script: TranscribeScript, recorder: EventRecorder) {
    let capture = FakeCapture()
    let script = TranscribeScript(responses: responses, failure: failure)
    let recorder = EventRecorder()
    var config = StreamingRealtimeLoop.Configuration()
    config.useVAD = useVAD
    config.wantsConfirmedAudio = wantsConfirmedAudio
    let loop = StreamingRealtimeLoop(
        configuration: config,
        decodingOptions: DecodingOptions(),
        dependencies: .init(
            requestPermission: { permissionGranted },
            startCapture: { capture.install($0) },
            stopCapture: { capture.markStopped() },
            transcribe: { samples, options, _ in try await script.invoke(samples, options) },
            tick: { try await Task.sleep(nanoseconds: 1_000_000) }
        ),
        onPartial: { recorder.recordPartial($0) },
        onEnergy: { _ in },
        onConfirmed: { recorder.recordBatch($0) }
    )
    return (loop, capture, script, recorder)
}

@Suite("Streaming realtime loop")
struct StreamingRealtimeLoopTests {
    @Test("confirmed timestamps stay absolute across a purge boundary")
    func timestampsAbsoluteAcrossPurge() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 4, "a"), segment(4, 8, "b"), segment(8, 9, "c")],
            [segment(2, 6, "d"), segment(6, 10, "e"), segment(10, 12, "f")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushRamp(seconds: 10)
        #expect(await eventually { await script.callCount == 1 })
        let call1 = try #require(await script.calls.first)
        #expect(call1.sampleCount == 10 * sampleRate)
        #expect(call1.clip == [0])

        #expect(await eventually { recorder.batches.count == 1 })
        let batch1 = try #require(recorder.batches.first)
        #expect(batch1.segments.map(\.text) == ["a"])
        #expect(batch1.segments.map(\.start) == [0])
        #expect(batch1.segments.map(\.end) == [4])

        #expect(await eventually { await loop.windowStartOffsetSamples() == 2 * sampleRate })
        #expect(await loop.windowSampleCount() == 8 * sampleRate)

        capture.push(seconds: 6, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        let call2 = try #require(await script.calls.last)
        #expect(call2.sampleCount == 14 * sampleRate)
        #expect(call2.clip == [2])
        #expect(call2.firstSample == Float(2 * sampleRate) / Float(10 * sampleRate))

        #expect(await eventually { recorder.batches.count == 2 })
        let batch2 = try #require(recorder.batches.last)
        #expect(batch2.segments.map(\.text) == ["d"])
        #expect(batch2.segments.map(\.start) == [4])
        #expect(batch2.segments.map(\.end) == [8])

        #expect(await eventually { await loop.windowStartOffsetSamples() == 6 * sampleRate })
        #expect(await loop.windowSampleCount() == 10 * sampleRate)

        #expect(recorder.partials.contains("b c"))
        #expect(recorder.partials.contains("e f"))

        await loop.stop()
        _ = await runTask.value
    }

    @Test("confirmed batches carry the audio slice for the confirmed span")
    func confirmedBatchesCarryAudio() async throws {
        let (loop, capture, script, recorder) = makeLoop(
            responses: [
                [segment(0, 4, "a"), segment(4, 8, "b"), segment(8, 9, "c")],
                [segment(2, 6, "d"), segment(6, 10, "e"), segment(10, 12, "f")],
            ],
            wantsConfirmedAudio: true
        )
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushRamp(seconds: 10)
        #expect(await eventually { recorder.batches.count == 1 })
        let batch1 = try #require(recorder.batches.first)
        #expect(batch1.windowStartSeconds == 0)
        #expect(batch1.audioWindow.count == Int(4.5 * Double(sampleRate)))

        capture.push(seconds: 6, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        #expect(await eventually { recorder.batches.count == 2 })
        let batch2 = try #require(recorder.batches.last)
        #expect(batch2.windowStartSeconds == 3.5)
        #expect(batch2.audioWindow.count == 5 * sampleRate)
        #expect(batch2.audioWindow.first == Float(Int(3.5 * Double(sampleRate))) / Float(10 * sampleRate))

        await loop.stop()
        _ = await runTask.value
    }

    @Test("VAD holds transcription until voice appears")
    func vadGatesTranscription() async throws {
        let (loop, capture, script, recorder) = makeLoop(
            responses: [[segment(3, 4, "hi")]],
            useVAD: true
        )
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushBuffers(count: 30, secondsEach: 0.1, value: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await script.callCount == 0)
        #expect(recorder.partials.contains("Waiting for speech..."))

        capture.pushBuffers(count: 20, secondsEach: 0.1, value: 0.5)
        #expect(await eventually { await script.callCount >= 1 })

        await loop.stop()
        _ = await runTask.value
    }

    @Test("stop ends the loop and freezes all outputs")
    func stopEndsLoop() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 4, "a"), segment(4, 8, "b"), segment(8, 9, "c")],
            [segment(2, 6, "d"), segment(6, 10, "e"), segment(10, 12, "f")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushRamp(seconds: 10)
        #expect(await eventually { recorder.batches.count == 1 })

        await loop.stop()
        let outcome = await runTask.value
        guard case .stopped = outcome else {
            Issue.record("expected .stopped, got \(outcome)")
            return
        }
        #expect(capture.stopped)

        capture.push(seconds: 6, value: 0.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await script.callCount == 1)
        #expect(recorder.batches.count == 1)
    }

    @Test("denied permission ends the run before capture starts")
    func permissionDenied() async throws {
        let (loop, capture, _, _) = makeLoop(responses: [], permissionGranted: false)
        let outcome = await loop.run()
        guard case .permissionDenied = outcome else {
            Issue.record("expected .permissionDenied, got \(outcome)")
            return
        }
        #expect(!capture.installed)
    }

    @Test("a transcription error fails the run and stops capture")
    func transcribeFailureStopsCapture() async throws {
        let (loop, capture, _, _) = makeLoop(responses: [], failure: ScriptError())
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 2, value: 0.5)
        let outcome = await runTask.value
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(capture.stopped)
    }
}
