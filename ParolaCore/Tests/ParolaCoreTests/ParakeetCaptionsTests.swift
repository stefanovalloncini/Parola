import Foundation
import Testing
import os
@preconcurrency import FluidAudio
@preconcurrency import WhisperKit
@testable import ParolaCore

private let sampleRate = 16_000

private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
    TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
}

private func result(_ timings: [TokenTiming], duration: Double = 0) -> ASRResult {
    ASRResult(
        text: timings.map(\.token).joined(), confidence: 0.9, duration: duration, processingTime: 0, tokenTimings: timings
    )
}

@Suite("Parakeet segmenting for captions")
struct ParakeetCaptionSegmentTests {
    private let twoSentences = [
        token(" Hello", 0, 0.4), token(" there", 0.4, 0.8), token(".", 0.8, 0.85),
        token(" How", 0.9, 1.2), token(" are", 1.2, 1.5), token(" you", 1.5, 1.8), token("?", 1.8, 1.85),
    ]

    @Test("sentence-final punctuation ends a caption segment, and a batch run is unchanged")
    func splitsOnPunctuation() {
        let captions = ParakeetTranscriber.makeSegments(from: result(twoSentences), includeWords: false, splitting: .captions)
        #expect(captions.map(\.text) == ["Hello there.", "How are you?"])
        #expect(captions.map(\.start) == [0, 0.9])

        let batch = ParakeetTranscriber.makeSegments(from: result(twoSentences), includeWords: false)
        #expect(batch.map(\.text) == ["Hello there. How are you?"])
    }

    @Test("a dot inside a number or an abbreviation does not end a segment")
    func dotInsideAWord() {
        let timings = [
            token(" It", 0, 0.2), token(" costs", 0.2, 0.5), token(" 3", 0.5, 0.7), token(".", 0.7, 0.75),
            token("5", 0.75, 0.9), token(" euros", 0.9, 1.3), token(".", 1.3, 1.35),
        ]
        let segments = ParakeetTranscriber.makeSegments(from: result(timings), includeWords: false, splitting: .captions)
        #expect(segments.map(\.text) == ["It costs 3.5 euros."])
    }

    @Test("a run with no punctuation and no pause is cut at the span limit, between words")
    func cutsLongRunsByDuration() {
        let pieces = (0..<30).flatMap { index -> [TokenTiming] in
            let start = Double(index) * 0.5
            return [token(" fo", start, start + 0.2), token("llowing", start + 0.2, start + 0.45)]
        }
        let segments = ParakeetTranscriber.makeSegments(from: result(pieces), includeWords: false, splitting: .captions)
        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { $0.end - $0.start <= 7 })
        let words = segments.flatMap { $0.text.split(separator: " ") }
        #expect(words.count == 30)
        #expect(words.allSatisfy { $0 == "following" })
    }
}

@Suite("Parakeet caption cuts at pauses")
struct ParakeetCaptionPauseTests {
    @Test("past four seconds a short pause ends the segment before the hard limit")
    func shortPauseAfterFourSeconds() {
        let words = (0..<16).map { index -> TokenTiming in
            let start = Double(index) * 0.5 + (index >= 10 ? 0.3 : 0)
            return token(" w\(index)", start, start + 0.4)
        }
        let segments = ParakeetTranscriber.makeSegments(from: result(words), includeWords: false, splitting: .captions)
        #expect(segments.map { $0.text.split(separator: " ").count } == [10, 6])
    }

    @Test("a short pause inside the first four seconds does not split")
    func shortPauseEarly() {
        let words = (0..<6).map { index -> TokenTiming in
            let start = Double(index) * 0.5 + (index >= 3 ? 0.3 : 0)
            return token(" w\(index)", start, start + 0.4)
        }
        let segments = ParakeetTranscriber.makeSegments(from: result(words), includeWords: false, splitting: .captions)
        #expect(segments.count == 1)
    }
}

@Suite("Parakeet streaming decoder")
struct ParakeetStreamingDecoderTests {
    private static func options() -> TranscriptionOptions {
        TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2", language: "en")
    }

    @Test("it decodes from the clip and shifts the timings back by the offset")
    func clipOffsetAndShift() async throws {
        let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let decoder = ParakeetStreamingDecoder.decoder(options: Self.options()) { samples in
            seen.withLock { $0.append(samples.count) }
            return result([token(" Hello", 0.5, 0.9), token(" world", 0.9, 1.3), token(".", 1.3, 1.35)])
        }
        var decoding = decoder.options
        decoding.clipTimestamps = [6]

        let decoded = try await decoder.transcribe([Float](repeating: 0.1, count: 10 * sampleRate), decoding) { _ in true }

        #expect(seen.withLock { $0 } == [4 * sampleRate])
        let segment = try #require(decoded.segments.first)
        #expect(segment.text == "Hello world.")
        #expect(abs(segment.start - 6.5) < 0.001)
        #expect(abs(segment.end - 7.35) < 0.001)
        #expect(decoded.language == "en")
    }

    @Test("word timings shift with their segment")
    func wordsShift() async throws {
        var options = Self.options()
        options.wordTimestamps = true
        let decoder = ParakeetStreamingDecoder.decoder(options: options) { _ in
            result([token(" Hello", 0, 0.4), token(" world", 0.4, 0.9)])
        }
        var decoding = decoder.options
        decoding.clipTimestamps = [2]

        let decoded = try await decoder.transcribe([Float](repeating: 0.1, count: 5 * sampleRate), decoding) { _ in true }

        let words = try #require(decoded.segments.first?.words)
        #expect(words.map(\.word) == ["Hello", "world"])
        #expect(abs(words[1].start - 2.4) < 0.001)
    }

    @Test("word timings are built whatever the setting, for the loop to align with")
    func wordsAreAlwaysBuilt() async throws {
        let decoder = ParakeetStreamingDecoder.decoder(options: Self.options()) { _ in
            result([token(" Hello", 0, 0.4), token(" world", 0.4, 0.9)])
        }

        let decoded = try await decoder.transcribe([Float](repeating: 0.1, count: 5 * sampleRate), decoder.options) { _ in true }

        #expect(decoded.segments.first?.words?.map(\.word) == ["Hello", "world"])
    }

    @Test("a slice never exceeds one encoder pass, whatever the clip says")
    func sliceIsClamped() async throws {
        let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let decoder = ParakeetStreamingDecoder.decoder(options: Self.options()) { samples in
            seen.withLock { $0.append(samples.count) }
            return result([])
        }
        var decoding = decoder.options
        decoding.clipTimestamps = [1]

        _ = try await decoder.transcribe([Float](repeating: 0.1, count: 20 * sampleRate), decoding) { _ in true }

        #expect(seen.withLock { $0 } == [ASRConstants.maxModelSamples])
    }

    @Test("a slice shorter than the model's minimum is an empty result, not an error")
    func tinySliceIsEmpty() async throws {
        let called = OSAllocatedUnfairLock(initialState: false)
        let decoder = ParakeetStreamingDecoder.decoder(options: Self.options()) { _ in
            called.withLock { $0 = true }
            return result([])
        }
        var decoding = decoder.options
        decoding.clipTimestamps = [2.9]

        let decoded = try await decoder.transcribe([Float](repeating: 0.1, count: 3 * sampleRate), decoding) { _ in true }

        #expect(decoded.segments.isEmpty)
        #expect(!called.withLock { $0 })
    }
}

private final class Mic: Sendable {
    private let callback = OSAllocatedUnfairLock<(@Sendable ([Float]) -> Bool)?>(initialState: nil)

    func install(_ new: @escaping @Sendable ([Float]) -> Bool) { callback.withLock { $0 = new } }
    var installed: Bool { callback.withLock { $0 != nil } }

    func push(seconds: Double) {
        let handler = callback.withLock { $0 }
        _ = handler?([Float](repeating: 0.1, count: Int(seconds * Double(sampleRate))))
    }
}

private func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func eventuallyAsync(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func parakeetConfiguration() -> StreamingRealtimeLoop.Configuration {
    StreamingTranscriptionSession.loopConfiguration(engine: .parakeet, wantsConfirmedAudio: false, waitsForModelOnStop: false)
}

/// Speech that never pauses: a word every half second, as heard up to `heard` seconds. `segmentable` gives the decoder token timings, with a sentence end every eight words when `punctuated`; without it each decode is one unbroken segment.
private final class NonstopSpeech: Sendable {
    struct Decode: Sendable {
        var sliceStart: Double
        var sliceSeconds: Double
        var confirmedEnd: Double
    }

    private struct State {
        var heard = 0.0
        var confirmedEnd = 0.0
        var decodes: [Decode] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let punctuated: Bool
    let segmentable: Bool

    init(punctuated: Bool, segmentable: Bool = true) {
        self.punctuated = punctuated
        self.segmentable = segmentable
    }

    var decodes: [Decode] { state.withLock { $0.decodes } }
    var decodedSeconds: [Double] { decodes.map(\.sliceSeconds) }
    var decodeCount: Int { state.withLock { $0.decodes.count } }
    func hear(_ seconds: Double) { state.withLock { $0.heard += seconds } }
    func confirm(end: Double) { state.withLock { $0.confirmedEnd = max($0.confirmedEnd, end) } }

    func recognize(_ samples: [Float]) -> ASRResult {
        let (heard, sliceSeconds) = state.withLock { state -> (Double, Double) in
            let seconds = Double(samples.count) / Double(sampleRate)
            state.decodes.append(Decode(sliceStart: state.heard - seconds, sliceSeconds: seconds, confirmedEnd: state.confirmedEnd))
            return (state.heard, seconds)
        }
        let sliceStart = heard - sliceSeconds
        var timings: [TokenTiming] = []
        var index = Int((sliceStart / 0.5).rounded(.up))
        while Double(index) * 0.5 + 0.45 <= heard + 1e-9 {
            let start = Double(index) * 0.5 - sliceStart
            timings.append(token(" w\(index)", start, start + 0.45))
            if punctuated, index % 8 == 7 { timings.append(token(".", start + 0.45, start + 0.46)) }
            index += 1
        }
        guard segmentable else {
            return ASRResult(text: timings.map(\.token).joined(), confidence: 0.9, duration: sliceSeconds, processingTime: 0)
        }
        return result(timings, duration: sliceSeconds)
    }
}

@Suite("Parakeet captions in the realtime loop")
struct ParakeetCaptionsLoopTests {
    private struct Run {
        var speech: NonstopSpeech
        var words: [Int]
        var windowSamples: [Int]
    }

    private func runNonstop(speech: NonstopSpeech, steps: Int = 60) async throws -> Run {
        let decoder = ParakeetStreamingDecoder.decoder(options: TranscriptionOptions(language: "en")) { speech.recognize($0) }
        let mic = Mic()
        let confirmed = OSAllocatedUnfairLock<[String]>(initialState: [])
        var config = parakeetConfiguration()
        config.useVAD = false
        let loop = StreamingRealtimeLoop(
            configuration: config,
            decodingOptions: decoder.options,
            dependencies: .init(
                requestPermission: { true },
                startCapture: { mic.install($0) },
                stopCapture: {},
                transcribe: decoder.transcribe,
                tick: { try await Task.sleep(nanoseconds: 200_000) }
            ),
            onPartial: { _ in },
            onEnergy: { _ in },
            onConfirmed: { batch in
                speech.confirm(end: Double(batch.segments.map(\.end).max() ?? 0))
                confirmed.withLock { $0.append(contentsOf: batch.segments.map(\.text)) }
            }
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        var windowSamples: [Int] = []
        for step in 1...steps {
            speech.hear(1.5)
            mic.push(seconds: 1.5)
            #expect(await eventually { speech.decodeCount >= step })
            windowSamples.append(await loop.windowSampleCount())
        }
        await loop.stop()
        _ = await run.value

        let words = confirmed.withLock { $0 }.flatMap { $0.split(separator: " ") }
            .compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).dropFirst()) }
        return Run(speech: speech, words: words, windowSamples: windowSamples)
    }

    @Test("nonstop punctuated speech keeps every decode within one encoder pass and loses no word")
    func nonstopPunctuated() async throws {
        let run = try await runNonstop(speech: NonstopSpeech(punctuated: true))
        #expect(run.speech.decodedSeconds.allSatisfy { $0 <= 15.001 }, "\(run.speech.decodedSeconds.max() ?? 0)")
        #expect(run.words == Array(0..<run.words.count), "confirmed words skip or repeat")
        #expect(run.words.count >= 170)
    }

    @Test("nonstop speech with no punctuation is cut by length and still loses no word")
    func nonstopUnpunctuated() async throws {
        let run = try await runNonstop(speech: NonstopSpeech(punctuated: false))
        #expect(run.speech.decodedSeconds.allSatisfy { $0 <= 15.001 }, "\(run.speech.decodedSeconds.max() ?? 0)")
        #expect(run.words == Array(0..<run.words.count), "confirmed words skip or repeat")
        #expect(run.words.count >= 170)
    }

    @Test("speech the segmenter can't cut runs past 60 s on force-confirm alone, with a bounded window and no skipped audio")
    func nonstopUncuttable() async throws {
        let run = try await runNonstop(speech: NonstopSpeech(punctuated: false, segmentable: false), steps: 50)
        let decodes = run.speech.decodes
        #expect(decodes.allSatisfy { $0.sliceSeconds <= 15.001 }, "\(run.speech.decodedSeconds.max() ?? 0)")
        #expect(decodes.map(\.sliceSeconds).max() ?? 0 > 10, "the held segment never grew, so the reach rule wasn't exercised")
        #expect(decodes.allSatisfy { $0.sliceStart >= $0.confirmedEnd - 3.001 }, "a decode went back past its left context")
        let bound = Int((15 + 3.5 + 1.5) * Double(sampleRate))
        #expect(run.windowSamples.allSatisfy { $0 <= bound }, "\(run.windowSamples.max() ?? 0)")
        #expect(run.words == Array(0..<run.words.count), "confirmed words skip or repeat")
        #expect(run.words.count >= 140)
    }
}

private actor Calls {
    private(set) var clips: [[Float]] = []
    private var queued: [[TranscriptionSegment]]

    init(_ responses: [[TranscriptionSegment]]) { queued = responses }

    func next(clip: [Float]) -> TranscriptionResult {
        clips.append(clip)
        let segments = queued.isEmpty ? [] : queued.removeFirst()
        return TranscriptionResult(text: "", segments: segments, language: "en", timings: TranscriptionTimings())
    }
}

private func scripted(
    _ responses: [[TranscriptionSegment]], configuration: StreamingRealtimeLoop.Configuration
) -> (loop: StreamingRealtimeLoop, mic: Mic, calls: Calls, confirmed: OSAllocatedUnfairLock<[String]>, partials: OSAllocatedUnfairLock<[String]>) {
    let mic = Mic()
    let partials = OSAllocatedUnfairLock<[String]>(initialState: [])
    let calls = Calls(responses)
    let confirmed = OSAllocatedUnfairLock<[String]>(initialState: [])
    var config = configuration
    config.useVAD = false
    let loop = StreamingRealtimeLoop(
        configuration: config,
        decodingOptions: DecodingOptions(),
        dependencies: .init(
            requestPermission: { true },
            startCapture: { mic.install($0) },
            stopCapture: {},
            transcribe: { _, options, _ in await calls.next(clip: options.clipTimestamps) },
            tick: { try await Task.sleep(nanoseconds: 1_000_000) }
        ),
        onPartial: { text in partials.withLock { $0.append(text) } },
        onEnergy: { _ in },
        onConfirmed: { batch in confirmed.withLock { $0.append(contentsOf: batch.segments.map(\.text)) } }
    )
    return (loop, mic, calls, confirmed, partials)
}

private func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text)
}

@Suite("Caption confirmation rules")
struct CaptionConfirmationTests {
    @Test("Whisper holds back two segments and never force-confirms an old one")
    func whisperUnchanged() async throws {
        let (loop, mic, calls, confirmed, _) = scripted(
            [[segment(0, 2, "a"), segment(2, 4, "b"), segment(4, 6, "c"), segment(6, 7, "d")]],
            configuration: StreamingRealtimeLoop.Configuration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 30)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })

        #expect(confirmed.withLock { $0 } == ["a", "b"])
        #expect(await calls.clips == [[0]])
        await loop.cancel()
        _ = await run.value
    }

    @Test("Parakeet holds back one recent segment")
    func parakeetHoldback() async throws {
        let (loop, mic, _, confirmed, _) = scripted(
            [[segment(0, 2, "a"), segment(27, 29, "b")]], configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 30)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })

        #expect(confirmed.withLock { $0 } == ["a"])
        await loop.cancel()
        _ = await run.value
    }

    @Test("Parakeet confirms the held-back segment too once it ended more than 8 s before the window end")
    func parakeetForceConfirmsOldSegment() async throws {
        let (loop, mic, _, confirmed, _) = scripted(
            [[segment(0, 2, "a"), segment(2, 4, "b")]], configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 30)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })

        #expect(confirmed.withLock { $0 } == ["a", "b"])
        await loop.cancel()
        _ = await run.value
    }

    @Test("a held-back segment that went stale is confirmed before the next decode, which starts at most 15 s back")
    func staleSegmentConfirmedFirst() async throws {
        let (loop, mic, calls, confirmed, _) = scripted(
            [[segment(0, 4, "a"), spoken(4, 9, "b c d e f")], []],
            configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })
        mic.push(seconds: 12)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })

        #expect(confirmed.withLock { $0 } == ["a", "b c d e f"])
        let clips = await calls.clips
        #expect(clips.count == 2)
        // The first decode purged the window to 3.5 s before the held segment; the second starts 2 s before its end (9 s), at the word "e", 6.5 s into what is left.
        #expect(clips.last == [6.5])
        await loop.cancel()
        _ = await run.value
    }
}

@Suite("Held segment anchor")
struct HeldAnchorTests {
    @Test("a decode that drops the held segment's first word doesn't move the next decode past it")
    func anchorSurvivesADroppedHead() async throws {
        let (loop, mic, calls, confirmed, partials) = scripted(
            [[spoken(0, 5, "if nothing", words: [("if", 0, 2.9), ("nothing", 3.0, 3.5)]), spoken(5, 9, "ship the following")],
             [inSecondWindow(spoken(6, 10, "following"))],
             [inSecondWindow(spoken(4.9, 8, "the following now"))]],
            configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })
        mic.push(seconds: 1)
        #expect(await eventuallyAsync { await calls.clips.count == 2 })
        mic.push(seconds: 1)
        #expect(await eventuallyAsync { await calls.clips.count == 3 })

        let clips = await calls.clips.map { $0.first ?? -1 }
        #expect(abs(clips[1] - 1.5) < 0.001 && abs(clips[2] - 1.5) < 0.001, "\(clips)")
        #expect(await eventually { partials.withLock { $0.last } == "the following now" })
        await loop.cancel()
        _ = await run.value
    }
}

@Suite("Caption decode gate")
struct CaptionDecodeGateTests {
    @Test("a decode runs once the new audio reaches the engine's minimum, not only past it")
    func gateIsInclusive() async throws {
        for (configuration, seconds) in [
            (StreamingRealtimeLoop.Configuration(), 1.0),
            (parakeetConfiguration(), 0.7),
        ] {
            let (loop, mic, calls, _, _) = scripted([[]], configuration: configuration)
            let run = Task { await loop.run() }
            #expect(await eventually { mic.installed })

            mic.push(seconds: seconds)

            #expect(await eventuallyAsync { await calls.clips.count == 1 }, "\(seconds) s")
            await loop.cancel()
            _ = await run.value
        }
    }
}

/// Words spread evenly over the segment, which is how the loop times a segment that has none.
private func spoken(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    let pieces = text.split(separator: " ").map(String.init)
    let step = (end - start) / Float(pieces.count)
    return spoken(start, end, text, words: pieces.enumerated().map { ($1, start + step * Float($0), start + step * Float($0 + 1)) })
}

private func spoken(_ start: Float, _ end: Float, _ text: String, words: [(String, Float, Float)]) -> TranscriptionSegment {
    var made = TranscriptionSegment(start: start, end: end, text: text)
    made.words = words.map { .init(word: $0.0, tokens: [], start: $0.1, end: $0.2, probability: 1) }
    return made
}

/// The first decode confirms [0, 5] and the purge keeps 3.5 s before it, so the second decode's window starts 1.5 s in.
private let secondWindowStart: Float = 1.5

private func inSecondWindow(_ segment: TranscriptionSegment) -> TranscriptionSegment {
    var moved = segment
    moved.start -= secondWindowStart
    moved.end -= secondWindowStart
    moved.words = segment.words?.map { word in
        var moved = word
        moved.start -= secondWindowStart
        moved.end -= secondWindowStart
        return moved
    }
    return moved
}

@Suite("Caption cuts inside a word")
struct CaptionCutRepeatTests {
    private struct Shown {
        var partial: String?
        var clip: Float?
    }

    private func afterTheSecondDecode(
        first: String, held: String, second: [TranscriptionSegment], configuration: StreamingRealtimeLoop.Configuration = parakeetConfiguration()
    ) async throws -> Shown {
        try await afterTheSecondDecode(first: spoken(0, 5, first), held: held, second: second, configuration: configuration)
    }

    private func afterTheSecondDecode(
        first: TranscriptionSegment, held: String, second: [TranscriptionSegment], configuration: StreamingRealtimeLoop.Configuration = parakeetConfiguration()
    ) async throws -> Shown {
        var configuration = configuration
        configuration.requiredSegmentsForConfirmation = 1
        let (loop, mic, calls, confirmed, partials) = scripted(
            [[first, spoken(5, 9, held)], second.map(inSecondWindow), second.map(inSecondWindow)],
            configuration: configuration
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })
        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })
        mic.push(seconds: 2)
        #expect(await eventuallyAsync { await calls.clips.count == 2 })
        mic.push(seconds: 1)
        #expect(await eventuallyAsync { await calls.clips.count == 3 })
        let shown = Shown(partial: partials.withLock { $0.last }, clip: await calls.clips[1].first)
        await loop.cancel()
        _ = await run.value
        return shown
    }

    @Test("a decode after a confirm starts 2 s before the held audio")
    func clipHasLeftContext() async throws {
        let first = spoken(0, 5, "if nothing", words: [("if", 0, 2.9), ("nothing", 3.0, 5.0)])
        let shown = try await afterTheSecondDecode(first: first, held: "else", second: [spoken(3, 9, "nothing else matters")])
        #expect(shown.clip == 1.5)
    }

    @Test("a context that would start inside a confirmed word starts at the word")
    func clipSnapsToAWordStart() async throws {
        let shown = try await afterTheSecondDecode(first: "if nothing", held: "else", second: [spoken(2.5, 9, "nothing else matters")])
        #expect(shown.clip == 1.0)
    }

    @Test("the clip starts at the last confirmed segment when it is within 3 s of the held audio")
    func clipStartsAtTheConfirmedSegment() async throws {
        let (loop, mic, calls, confirmed, _) = scripted(
            [[spoken(0, 2, "one"), spoken(2, 5, "two three"), spoken(5, 9, "four")], []], configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })
        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })
        mic.push(seconds: 2)
        #expect(await eventuallyAsync { await calls.clips.count == 2 })

        // The segment "two three" starts at 2 s; the purge left the window starting 1.5 s in.
        let started = try #require(await calls.clips.last?.first)
        #expect(abs(started - 0.5) < 0.001, "\(started)")
        await loop.cancel()
        _ = await run.value
    }

    @Test("the left context is dropped, so a sentence that continues after a comma stays in lower case")
    func contextWordsBeforeTheBoundaryAreDropped() async throws {
        let shown = try await afterTheSecondDecode(
            first: "as soon as they finish a sentence,", held: "that is",
            second: [spoken(3, 9, "finish a sentence, that is exactly")]
        )
        #expect(shown.partial == "that is exactly")
    }

    @Test("after a sentence end the decode starts at the held audio, and a repeat of the last word stays")
    func repeatAfterASentenceStays() async throws {
        let shown = try await afterTheSecondDecode(
            first: "Is that okay?", held: "Okay,", second: [spoken(5.05, 9, "Okay, let's move on")]
        )
        #expect(shown.partial == "Okay, let's move on")
        #expect(shown.clip == 3.5)
    }

    @Test("nothing is dropped when the decode started at the held audio, whatever it returns")
    func repeatAfterASentenceStaysWithContext() async throws {
        let shown = try await afterTheSecondDecode(
            first: "Is that okay?", held: "Okay,", second: [spoken(3, 9, "that okay? Okay, let's move on")]
        )
        #expect(shown.partial == "that okay? Okay, let's move on")
    }

    @Test("a repeat right after the confirmed word stays even when the context starts on that word")
    func repeatStays() async throws {
        let shown = try await afterTheSecondDecode(
            first: "I said that,", held: "that", second: [spoken(3, 9, "that, that is fine")]
        )
        #expect(shown.partial == "that is fine")
        let inside = try await afterTheSecondDecode(
            first: "I said that,", held: "that", second: [spoken(3, 9, "said that, that is fine")]
        )
        #expect(inside.partial == "that is fine")
    }

    @Test("a hard cut's repeated tail word is dropped by alignment, while Whisper keeps both")
    func repeatedWordAtTheCut() async throws {
        let context = try await afterTheSecondDecode(
            first: "if nothing the", held: "following", second: [spoken(3, 9, "nothing the following now")]
        )
        #expect(context.partial == "following now")
        let withoutContext = try await afterTheSecondDecode(
            first: "if nothing the", held: "following", second: [spoken(5.05, 9, "the following now")]
        )
        #expect(withoutContext.partial == "following now")

        let whisper = try await afterTheSecondDecode(
            first: "if nothing the", held: "following", second: [spoken(5.05, 9, "the following now")],
            configuration: StreamingRealtimeLoop.Configuration()
        )
        #expect(whisper.partial == "the following now")
    }

    @Test("a held first word timed a frame before the boundary is kept")
    func jitteredFirstWordIsKept() async throws {
        let shown = try await afterTheSecondDecode(
            first: "we found a few cases where", held: "the audio device",
            second: [spoken(3, 6, "a few cases where the audio device changed", words: [
                ("a", 3.0, 3.4), ("few", 3.4, 3.8), ("cases", 3.8, 4.4), ("where", 4.4, 4.88),
                ("the", 4.88, 4.96), ("audio", 4.96, 5.4), ("device", 5.4, 5.8), ("changed", 5.8, 6.0),
            ])]
        )
        #expect(shown.partial == "the audio device changed")
    }

    @Test("when no context word aligns, the words heard before the boundary go, wherever the segment starts")
    func unalignedContextFallsBackToWords() async throws {
        let shown = try await afterTheSecondDecode(
            first: "if nothing", held: "else",
            second: [spoken(3, 6.2, "something different new words here", words: [
                ("something", 3.0, 3.8), ("different", 3.8, 4.6), ("new", 5.0, 5.4), ("words", 5.4, 5.8), ("here", 5.8, 6.2),
            ])]
        )
        #expect(shown.partial == "new words here")
    }

    @Test("a revised last confirmed word aligns nothing, and the doubled context still goes")
    func revisedLastWordDropsTheContext() async throws {
        let shown = try await afterTheSecondDecode(
            first: "as we were testing on real machines, and ship", held: "the following Monday.",
            second: [spoken(3, 7, "real machines, and shipped the following Monday.", words: [
                ("real", 3.0, 3.4), ("machines,", 3.4, 4.0), ("and", 4.0, 4.3), ("shipped", 4.3, 4.9),
                ("the", 5.0, 5.3), ("following", 5.3, 6.0), ("Monday.", 6.0, 7.0),
            ])]
        )
        #expect(shown.partial == "the following Monday.")
    }

    @Test("a doubled phrase never reaches a confirmed line")
    func doubledContextIsNotConfirmed() async throws {
        let (loop, mic, calls, confirmed, _) = scripted(
            [[spoken(0, 5, "as we were testing on real machines, and ship"), spoken(5, 9, "the following Monday.")],
             [inSecondWindow(spoken(3, 7, "real machines, and shipped the following Monday.", words: [
                ("real", 3.0, 3.4), ("machines,", 3.4, 4.0), ("and", 4.0, 4.3), ("shipped", 4.3, 4.9),
                ("the", 5.0, 5.3), ("following", 5.3, 6.0), ("Monday.", 6.0, 7.0),
             ])), inSecondWindow(spoken(7.2, 8.4, "That is all."))]],
            configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })
        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })
        mic.push(seconds: 2)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })

        #expect(confirmed.withLock { $0 } == ["as we were testing on real machines, and ship", "the following Monday."])
        _ = await calls.clips
        await loop.cancel()
        _ = await run.value
    }

    @Test("the run is matched among the words before the boundary, so a later repeat of the last word is not mistaken for it")
    func runEndStopsAtTheBoundary() async throws {
        let shown = try await afterTheSecondDecode(
            first: "we really want to ship it", held: "and ship it again",
            second: [spoken(3, 7, "to shipped it, and ship it again", words: [
                ("to", 3.0, 3.4), ("shipped", 3.4, 4.2), ("it,", 4.2, 4.9), ("and", 5.0, 5.3),
                ("ship", 5.3, 5.7), ("it", 5.7, 6.0), ("again", 6.0, 6.5),
            ])]
        )
        #expect(shown.partial == "and ship it again")
    }

    @Test("a decode that came back without its context keeps every word, even one the confirmed text ends on")
    func decodeWithoutContextKeepsTheHeldWords() async throws {
        let shown = try await afterTheSecondDecode(
            first: "we fixed it in the", held: "logs, then the build",
            second: [spoken(5.0, 9, "logs, then the build")]
        )
        #expect(shown.partial == "logs, then the build")
    }

    @Test("the context run is the longest suffix of the confirmed words, earliest on a tie")
    func contextRun() {
        let confirmed = ["is", "that", "okay"]
        #expect(StreamingRealtimeLoop.contextRunEnd(decoded: ["that", "okay", "okay", "let's"], confirmed: confirmed) == 1)
        #expect(StreamingRealtimeLoop.contextRunEnd(decoded: ["okay", "okay", "let's"], confirmed: confirmed) == 0)
        #expect(StreamingRealtimeLoop.contextRunEnd(decoded: ["so", "what"], confirmed: confirmed) == nil)
    }

    @Test("word timings are dropped from what the loop emits unless they were asked for")
    func wordsAreStrippedWhenNotRequested() async throws {
        for (asked, expected) in [(false, false), (true, true)] {
            let batches = OSAllocatedUnfairLock<[TranscriptionSegment]>(initialState: [])
            let mic = Mic()
            let calls = Calls([[spoken(0, 5, "if nothing"), spoken(5, 9, "else")]])
            var configuration = parakeetConfiguration()
            configuration.useVAD = false
            configuration.requiredSegmentsForConfirmation = 1
            var options = DecodingOptions()
            options.wordTimestamps = asked
            let loop = StreamingRealtimeLoop(
                configuration: configuration,
                decodingOptions: options,
                dependencies: .init(
                    requestPermission: { true },
                    startCapture: { mic.install($0) },
                    stopCapture: {},
                    transcribe: { _, options, _ in await calls.next(clip: options.clipTimestamps) },
                    tick: { try await Task.sleep(nanoseconds: 1_000_000) }
                ),
                onPartial: { _ in },
                onEnergy: { _ in },
                onConfirmed: { batch in batches.withLock { $0.append(contentsOf: batch.segments) } }
            )
            let run = Task { await loop.run() }
            #expect(await eventually { mic.installed })
            mic.push(seconds: 10)
            #expect(await eventually { !batches.withLock { $0 }.isEmpty })
            #expect(batches.withLock { $0.allSatisfy { ($0.words != nil) == expected } }, "asked \(asked)")
            await loop.cancel()
            _ = await run.value
        }
    }
}

@Suite("Parakeet captions session guards")
struct ParakeetCaptionsSessionTests {
    private static let v2 = "nvidia_parakeet-tdt-0.6b-v2"
    private static let v3 = "nvidia_parakeet-tdt-0.6b-v3"

    private static func session(purpose: StreamingPurpose) -> StreamingTranscriptionSession {
        StreamingTranscriptionSession(
            modelStore: ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("parakeet-captions-tests-\(UUID().uuidString)")),
            purpose: purpose
        )
    }

    private static func rejection(_ options: TranscriptionOptions, purpose: StreamingPurpose = .captions) async -> String? {
        do {
            _ = try await session(purpose: purpose).start(options: options)
            return nil
        } catch let ParolaError.unsupportedForEngine(text) {
            return text
        } catch {
            return "other: \(error)"
        }
    }

    @Test("v2 refuses a language other than English before any download")
    func v2RefusesItalian() async {
        let text = await Self.rejection(TranscriptionOptions(model: Self.v2, language: "it"))
        #expect(text?.hasSuffix("does not support \"it\"") == true, "\(text ?? "nil")")
    }

    @Test("translating is refused at start with the sentence the app translates")
    func translateRefused() async {
        for model in [Self.v2, Self.v3] {
            let text = await Self.rejection(TranscriptionOptions(model: model, task: .translate))
            #expect(text == FixedFailureText.cannotTranslate("Parakeet"), "\(model): \(text ?? "nil")")
        }
    }

    @Test("a dictation or live take on Parakeet is still refused")
    func takesStayRefused() async {
        let text = await Self.rejection(TranscriptionOptions(model: Self.v3), purpose: .take)
        #expect(text?.contains("can't stream") == true, "\(text ?? "nil")")
    }

    @Test("Apple Speech is refused for captions too")
    func appleSpeechRefused() async throws {
        let apple = try #require(ModelCatalog.all.first { $0.engineID == .appleSpeech })
        let text = await Self.rejection(TranscriptionOptions(model: apple.id))
        #expect(text?.contains("Whisper or Parakeet") == true, "\(text ?? "nil")")
        let take = await Self.rejection(TranscriptionOptions(model: apple.id), purpose: .take)
        #expect(take?.contains("Parakeet") == false, "\(take ?? "nil")")
    }

    @Test("the loop is configured per engine")
    func configurationPerEngine() {
        let whisper = StreamingTranscriptionSession.loopConfiguration(
            engine: .whisperKit, wantsConfirmedAudio: false, waitsForModelOnStop: false
        )
        #expect(whisper.requiredSegmentsForConfirmation == 2)
        #expect(whisper.forceConfirmAfterSeconds == nil)
        #expect(whisper.maxDecodeSeconds == nil)
        #expect(whisper.minNewAudioSeconds == 1)
        #expect(whisper.heldSegmentBackoffSeconds == nil)
        #expect(whisper.leftContextSeconds == nil)
        #expect(whisper.purgePadSeconds == 2)
        let parakeet = parakeetConfiguration()
        #expect(parakeet.requiredSegmentsForConfirmation == 1)
        #expect(parakeet.forceConfirmAfterSeconds == 8)
        #expect(parakeet.maxDecodeSeconds == 15)
        #expect(parakeet.minNewAudioSeconds == 0.7)
        #expect(parakeet.heldSegmentBackoffSeconds == 0.08)
        #expect(parakeet.leftContextSeconds == 2)
        #expect(parakeet.purgePadSeconds == 3.5)
    }
}
