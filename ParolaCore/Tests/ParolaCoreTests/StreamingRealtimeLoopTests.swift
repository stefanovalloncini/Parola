import Foundation
import Testing
import os
@preconcurrency import WhisperKit
@testable import ParolaCore

private let sampleRate = 16_000

private final class FakeCapture: Sendable {
    // A named struct, not a tuple: a tuple element is lowered at the lock's opaque abstraction, so every `withLock` adds a reabstraction-thunk pair to the callback.
    private struct State {
        var callback: (@Sendable ([Float]) -> Void)?
        var stops = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ callback: @escaping @Sendable ([Float]) -> Void) {
        state.withLock { $0.callback = callback }
    }

    func markStopped() {
        state.withLock { $0.stops += 1 }
    }

    var installed: Bool { state.withLock { $0.callback != nil } }
    var stopped: Bool { state.withLock { $0.stops > 0 } }
    var stopCount: Int { state.withLock { $0.stops } }

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

/// A first-run microphone prompt that stays up until the test answers it.
private actor PermissionPrompt {
    private var waiter: CheckedContinuation<Bool, Never>?
    private(set) var isShowing = false

    func ask() async -> Bool {
        isShowing = true
        return await withCheckedContinuation { waiter = $0 }
    }

    func answer(_ granted: Bool) {
        waiter?.resume(returning: granted)
        waiter = nil
    }
}

private func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text)
}

private func eventually(
    timeoutMs: Int = 5000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func makeLoop(
    responses: [[TranscriptionSegment]],
    failure: (any Error)? = nil,
    startFailure: (any Error)? = nil,
    useVAD: Bool = false,
    wantsConfirmedAudio: Bool = false,
    maxWindowSeconds: Double = 60,
    permissionGranted: Bool = true,
    requestPermission: (@Sendable () async -> Bool)? = nil
) -> (loop: StreamingRealtimeLoop, capture: FakeCapture, script: TranscribeScript, recorder: EventRecorder) {
    let capture = FakeCapture()
    let script = TranscribeScript(responses: responses, failure: failure)
    let recorder = EventRecorder()
    var config = StreamingRealtimeLoop.Configuration()
    config.useVAD = useVAD
    config.wantsConfirmedAudio = wantsConfirmedAudio
    config.maxWindowSeconds = maxWindowSeconds
    let loop = StreamingRealtimeLoop(
        configuration: config,
        decodingOptions: DecodingOptions(),
        dependencies: .init(
            requestPermission: requestPermission ?? { permissionGranted },
            startCapture: { callback in
                if let startFailure { throw startFailure }
                capture.install(callback)
            },
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
    @Test("polling the capture leaves its callback one frame deep")
    func pollingDoesNotNestTheCallback() {
        let capture = FakeCapture()
        let depths = OSAllocatedUnfairLock<[Int]>(initialState: [])
        capture.install { _ in depths.withLock { $0.append(Thread.callStackSymbols.count) } }
        capture.push([])
        for _ in 0..<200 { _ = capture.installed }
        capture.push([])
        let measured = depths.withLock { $0 }
        #expect(measured.count == 2)
        #expect(measured.first == measured.last)
    }

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

    @Test("a regressive segment at the end of the prefix keeps the rest confirmable")
    func regressiveSegmentKeepsPrefix() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 4, "a"), segment(4, 8, "b"), segment(8, 9, "c")],
            [
                segment(2, 6, "d"), segment(6, 10, "e"), segment(1, 1.5, "oops"),
                segment(10, 12, "f"), segment(12, 14, "g"),
            ],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 10, value: 0.5)
        #expect(await eventually { recorder.batches.count == 1 })
        #expect(recorder.batches.first?.segments.map(\.text) == ["a"])

        capture.push(seconds: 6, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        #expect(await eventually { recorder.batches.count == 2 })
        let batch = try #require(recorder.batches.last)
        #expect(batch.segments.map(\.text) == ["d", "e"], "the segment behind the watermark is the only one dropped")
        #expect(batch.segments.map(\.end) == [8, 12])

        #expect(await eventually { await loop.windowStartOffsetSamples() == 10 * sampleRate })

        await loop.stop()
        _ = await runTask.value
    }

    @Test("a confirmed end past the retained tail keeps the tail's audio")
    func overshootingEndKeepsRetainedAudio() async throws {
        let (loop, capture, script, recorder) = makeLoop(
            responses: [
                [segment(0, 9, "a"), segment(4, 6, "b"), segment(6, 8, "c")],
                [segment(2, 4, "b"), segment(4, 6, "c")],
            ],
            wantsConfirmedAudio: true
        )
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushRamp(seconds: 10)
        #expect(await eventually { recorder.batches.count == 1 })
        #expect(recorder.batches.first?.segments.map(\.text) == ["a"])
        #expect(await eventually { await loop.windowStartOffsetSamples() == 2 * sampleRate })

        capture.push(seconds: 2, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })

        await loop.stop()
        _ = await runTask.value

        #expect(recorder.batches.count == 2)
        let tail = try #require(recorder.batches.last)
        #expect(tail.segments.map(\.text) == ["b", "c"])
        #expect(tail.windowStartSeconds == 3.5)
        #expect(tail.audioWindow.count == 5 * sampleRate)
    }

    // Whisper pads short windows to 30 s and dates its hallucinations from the padding: a 1.1 s
    // window really does come back as one "[BLANK_AUDIO]" segment ending at 10 s.
    @Test("a hallucinated end past the decoded audio does not skip the speech that follows")
    func hallucinatedEndDoesNotSkipLaterSpeech() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 28, "[BLANK_AUDIO]"), segment(28, 29, "uh"), segment(29, 30, "uh")],
            [
                segment(2, 4, "the quick"), segment(4, 5, "brown fox"),
                segment(5, 6, "lazy dog"), segment(6, 7, "tail"),
            ],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 5, value: 0.5)
        #expect(await eventually { recorder.batches.count == 1 })
        #expect(
            await eventually { await loop.windowStartOffsetSamples() == 3 * sampleRate },
            "the watermark stops at the 5 s actually decoded, so the purge keeps the speech"
        )

        capture.push(seconds: 5, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        let call2 = try #require(await script.calls.last)
        #expect(call2.sampleCount == 7 * sampleRate)
        #expect(call2.clip == [2], "the decode starts inside the window, not past everything it holds")

        await loop.stop()
        _ = await runTask.value

        #expect(
            recorder.batches.flatMap { $0.segments.map(\.text) }
                == ["[BLANK_AUDIO]", "the quick", "brown fox", "lazy dog", "tail"],
            "the speech after the hallucination still reaches the transcript"
        )
    }

    @Test("the next decode clips behind a retained segment, not past it")
    func clipStaysBehindTheRetainedTail() async throws {
        let (loop, capture, script, _) = makeLoop(responses: [
            [segment(0, 9, "a"), segment(3, 5, "b"), segment(5, 7, "c")],
            [segment(2, 4, "b"), segment(4, 6, "c"), segment(6, 8, "d")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 10, value: 0.5)
        #expect(await eventually { await loop.windowStartOffsetSamples() == 1 * sampleRate })

        capture.push(seconds: 2, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        let call2 = try #require(await script.calls.last)
        #expect(call2.sampleCount == 11 * sampleRate)
        #expect(call2.clip == [2], "3 s in, where the retained segment starts")

        await loop.stop()
        _ = await runTask.value
    }

    @Test("a re-emitted segment is confirmed only once")
    func reEmittedSegmentIsConfirmedOnce() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 3, "one"), segment(3, 4, "two"), segment(4, 8, "three"), segment(8, 9, "four")],
            [segment(1, 2, "two"), segment(2, 6, "three"), segment(6, 7, "four"), segment(7, 9, "five")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 10, value: 0.5)
        #expect(await eventually { recorder.batches.count == 1 })
        #expect(await eventually { await loop.windowStartOffsetSamples() == 2 * sampleRate })

        capture.push(seconds: 4, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        #expect(await eventually { recorder.batches.count == 2 })

        await loop.stop()
        _ = await runTask.value

        #expect(
            recorder.batches.flatMap { $0.segments.map(\.text) } == ["one", "two", "three", "four", "five"],
            "the re-decoded segment ending at the watermark is not delivered twice"
        )
    }

    @Test("an out-of-order confirmed batch still carries its audio")
    func outOfOrderBatchCarriesAudio() async throws {
        let (loop, capture, _, recorder) = makeLoop(
            responses: [[
                segment(8, 9, "late"), segment(0, 1, "early"),
                segment(9, 10, "x"), segment(10, 11, "y"),
            ]],
            wantsConfirmedAudio: true
        )
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushRamp(seconds: 10)
        #expect(await eventually { recorder.batches.count == 1 })
        let batch = try #require(recorder.batches.first)
        #expect(batch.segments.map(\.text) == ["late", "early"])
        #expect(batch.windowStartSeconds == 0)
        #expect(batch.audioWindow.count == Int(9.5 * Double(sampleRate)))

        await loop.stop()
        _ = await runTask.value
    }

    @Test("a capture that fails to start is stopped exactly once")
    func startCaptureFailureStopsCapture() async throws {
        let (loop, capture, _, _) = makeLoop(responses: [], startFailure: ScriptError())
        let outcome = await loop.run()
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(capture.stopCount == 1)
        await loop.stop()
        #expect(capture.stopCount == 1)
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

    @Test("sustained silence caps the retained window")
    func silenceCapsWindow() async throws {
        let (loop, capture, script, _) = makeLoop(responses: [], useVAD: true)
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.pushBuffers(count: 70, secondsEach: 1, value: 0)
        #expect(await eventually { await loop.windowStartOffsetSamples() == 10 * sampleRate })
        #expect(await loop.windowSampleCount() == 60 * sampleRate)

        capture.pushBuffers(count: 10, secondsEach: 1, value: 0)
        #expect(await eventually { await loop.windowStartOffsetSamples() == 20 * sampleRate })
        #expect(await loop.windowSampleCount() == 60 * sampleRate)
        #expect(await script.callCount == 0)

        await loop.stop()
        _ = await runTask.value
    }

    @Test("the cap bounds the decode when segments never confirm")
    func capBoundsDecodeWithoutConfirmations() async throws {
        let (loop, capture, script, _) = makeLoop(responses: [[], []], maxWindowSeconds: 4)
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 3, value: 0.5)
        #expect(await eventually { await script.callCount == 1 })
        let call1 = try #require(await script.calls.first)
        #expect(call1.sampleCount == 3 * sampleRate)

        capture.push(seconds: 3, value: 0.5)
        #expect(await eventually { await script.callCount == 2 })
        let call2 = try #require(await script.calls.last)
        #expect(call2.sampleCount == 4 * sampleRate)
        #expect(await loop.windowStartOffsetSamples() == 2 * sampleRate)

        await loop.stop()
        _ = await runTask.value
    }

    @Test("stop promotes the unconfirmed tail and freezes further input")
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
        #expect(recorder.batches.count == 2, "the unconfirmed tail is promoted at stop")
        #expect(recorder.batches.last?.segments.map(\.text) == ["b", "c"])

        capture.push(seconds: 6, value: 0.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await script.callCount == 1)
        #expect(recorder.batches.count == 2)
    }

    @Test("stop decodes audio that arrived after the last iteration")
    func stopFlushesTrailingAudio() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 1, "a"), segment(1, 2, "b"), segment(2, 3, "c")],
            [segment(1, 2, "b"), segment(2, 3, "c"), segment(3, 3.5, "tail")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 3, value: 0.5)
        #expect(await eventually { await script.callCount == 1 })
        #expect(await eventually { recorder.batches.count == 1 })

        capture.push(seconds: 0.5, value: 0.5)
        await loop.stop()
        _ = await runTask.value

        #expect(await script.callCount == 2, "the sub-second tail is decoded at stop")
        let flushCall = try #require(await script.calls.last)
        #expect(flushCall.sampleCount == Int(3.5 * Double(sampleRate)))
        #expect(recorder.batches.count == 2)
        #expect(recorder.batches.last?.segments.map(\.text) == ["b", "c", "tail"], "the flush confirms everything it decodes")
    }

    @Test("stop after a silent tail skips the flush decode but keeps the last hypothesis")
    func stopSkipsFlushForSilence() async throws {
        let (loop, capture, script, recorder) = makeLoop(
            responses: [[segment(0, 1, "a"), segment(1, 2, "b"), segment(2, 3, "c")]],
            useVAD: true
        )
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        // The voice arrives as one buffer: split across many, an iteration landing mid-push
        // would leave undecoded speech in the tail and the flush would rightly decode it.
        capture.pushBuffers(count: 1, secondsEach: 0.1, value: 0)
        capture.push(seconds: 3, value: 0.5)
        #expect(await eventually { await script.callCount == 1 })
        #expect(await eventually { recorder.batches.count == 1 })

        capture.pushBuffers(count: 20, secondsEach: 0.1, value: 0)
        await loop.stop()
        _ = await runTask.value

        #expect(await script.callCount == 1, "a silence-only tail is not decoded")
        #expect(recorder.batches.count == 2)
        #expect(recorder.batches.last?.segments.map(\.text) == ["b", "c"])
    }

    @Test("cancelling the run releases the mic and skips the flush decode")
    func cancellationStopsCapture() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [
            [segment(0, 1, "a"), segment(1, 2, "b"), segment(2, 3, "c")],
            [segment(1, 2, "b"), segment(2, 3, "c"), segment(3, 3.5, "tail")],
        ])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 3, value: 0.5)
        #expect(await eventually { await script.callCount == 1 })
        #expect(await eventually { recorder.batches.count == 1 })

        capture.push(seconds: 0.5, value: 0.5)
        runTask.cancel()
        let outcome = await runTask.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }

        #expect(capture.stopCount == 1, "a cancelled run releases the mic")
        #expect(await script.callCount == 1, "a cancelled run does not decode a flush")
        #expect(recorder.batches.count == 1, "a cancelled run promotes no tail")
    }

    @Test("stopping after a cancelled run stops capture once")
    func cancelThenStopStopsCaptureOnce() async throws {
        let (loop, capture, _, _) = makeLoop(responses: [])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        runTask.cancel()
        _ = await runTask.value
        await loop.stop()
        #expect(capture.stopCount == 1)
    }

    @Test("cancelling after a stop stops capture once")
    func stopThenCancelStopsCaptureOnce() async throws {
        let (loop, capture, _, _) = makeLoop(responses: [])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        await loop.stop()
        let outcome = await runTask.value
        runTask.cancel()
        guard case .stopped = outcome else {
            Issue.record("expected .stopped, got \(outcome)")
            return
        }
        #expect(capture.stopCount == 1)
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

    @Test("cancel releases the mic and skips the flush decode a stop would run")
    func cancelSkipsTheFlush() async throws {
        let (loop, capture, script, recorder) = makeLoop(responses: [[segment(0, 0.5, "tail")]])
        let runTask = Task { await loop.run() }
        #expect(await eventually { capture.installed })

        capture.push(seconds: 0.5, value: 0.5)
        await loop.cancel()

        let outcome = await runTask.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
        #expect(capture.stopCount == 1)
        #expect(await script.callCount == 0)
        #expect(recorder.batches.isEmpty)
    }

    @Test("a stop during the permission prompt keeps capture from starting after Allow")
    func stopDuringPermissionPromptWins() async throws {
        let prompt = PermissionPrompt()
        let (loop, capture, script, _) = makeLoop(responses: [], requestPermission: { await prompt.ask() })
        let runTask = Task { await loop.run() }
        #expect(await eventually { await prompt.isShowing })

        await loop.stop()
        await prompt.answer(true)

        let outcome = await runTask.value
        guard case .stopped = outcome else {
            Issue.record("expected .stopped, got \(outcome)")
            return
        }
        #expect(!capture.installed, "no capture starts once the user has already stopped")
        #expect(await script.callCount == 0)
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
