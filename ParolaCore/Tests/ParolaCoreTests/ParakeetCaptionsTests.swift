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

    @Test("a run with no punctuation and no pause is cut at the span limit")
    func cutsLongRunsByDuration() {
        let words = (0..<30).map { token(" w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.45) }
        let segments = ParakeetTranscriber.makeSegments(from: result(words), includeWords: false, splitting: .captions)
        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { $0.end - $0.start <= 7 })
        #expect(segments.flatMap { $0.text.split(separator: " ") }.count == 30)
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

private func parakeetConfiguration() -> StreamingRealtimeLoop.Configuration {
    StreamingTranscriptionSession.loopConfiguration(engine: .parakeet, wantsConfirmedAudio: false, waitsForModelOnStop: false)
}

/// Speech that never pauses: a word every half second, as heard up to `heard` seconds, with a sentence end every eight words when `punctuated`.
private final class NonstopSpeech: Sendable {
    private struct State {
        var heard = 0.0
        var decodedSeconds: [Double] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let punctuated: Bool

    init(punctuated: Bool) { self.punctuated = punctuated }

    var decodedSeconds: [Double] { state.withLock { $0.decodedSeconds } }
    var decodeCount: Int { state.withLock { $0.decodedSeconds.count } }
    func hear(_ seconds: Double) { state.withLock { $0.heard += seconds } }

    func recognize(_ samples: [Float]) -> ASRResult {
        let (heard, sliceSeconds) = state.withLock { state -> (Double, Double) in
            let seconds = Double(samples.count) / Double(sampleRate)
            state.decodedSeconds.append(seconds)
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
        return result(timings, duration: sliceSeconds)
    }
}

@Suite("Parakeet captions in the realtime loop")
struct ParakeetCaptionsLoopTests {
    private func runNonstop(punctuated: Bool) async throws -> (speech: NonstopSpeech, words: [Int]) {
        let speech = NonstopSpeech(punctuated: punctuated)
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
                tick: { try await Task.sleep(nanoseconds: 1_000_000) }
            ),
            onPartial: { _ in },
            onEnergy: { _ in },
            onConfirmed: { batch in confirmed.withLock { $0.append(contentsOf: batch.segments.map(\.text)) } }
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        for step in 1...60 {
            speech.hear(1.5)
            mic.push(seconds: 1.5)
            #expect(await eventually { speech.decodeCount >= step })
        }
        await loop.stop()
        _ = await run.value

        let words = confirmed.withLock { $0 }.flatMap { $0.split(separator: " ") }
            .compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).dropFirst()) }
        return (speech, words)
    }

    @Test("nonstop punctuated speech keeps every decode within one encoder pass and loses no word")
    func nonstopPunctuated() async throws {
        let (speech, words) = try await runNonstop(punctuated: true)
        #expect(speech.decodedSeconds.allSatisfy { $0 <= 15.001 }, "\(speech.decodedSeconds.max() ?? 0)")
        #expect(words == Array(0..<words.count), "confirmed words skip or repeat")
        #expect(words.count >= 170)
    }

    @Test("nonstop speech with no punctuation is cut by length and still loses no word")
    func nonstopUnpunctuated() async throws {
        let (speech, words) = try await runNonstop(punctuated: false)
        #expect(speech.decodedSeconds.allSatisfy { $0 <= 15.001 }, "\(speech.decodedSeconds.max() ?? 0)")
        #expect(words == Array(0..<words.count), "confirmed words skip or repeat")
        #expect(words.count >= 170)
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
) -> (loop: StreamingRealtimeLoop, mic: Mic, calls: Calls, confirmed: OSAllocatedUnfairLock<[String]>) {
    let mic = Mic()
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
        onPartial: { _ in },
        onEnergy: { _ in },
        onConfirmed: { batch in confirmed.withLock { $0.append(contentsOf: batch.segments.map(\.text)) } }
    )
    return (loop, mic, calls, confirmed)
}

private func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text)
}

@Suite("Caption confirmation rules")
struct CaptionConfirmationTests {
    @Test("Whisper holds back two segments and never force-confirms an old one")
    func whisperUnchanged() async throws {
        let (loop, mic, calls, confirmed) = scripted(
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
        let (loop, mic, _, confirmed) = scripted(
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
        let (loop, mic, _, confirmed) = scripted(
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
        let (loop, mic, calls, confirmed) = scripted(
            [[segment(0, 4, "a"), segment(4, 9, "b")], []],
            configuration: parakeetConfiguration()
        )
        let run = Task { await loop.run() }
        #expect(await eventually { mic.installed })

        mic.push(seconds: 10)
        #expect(await eventually { confirmed.withLock { $0.count } == 1 })
        mic.push(seconds: 12)
        #expect(await eventually { confirmed.withLock { $0.count } == 2 })

        #expect(confirmed.withLock { $0 } == ["a", "b"])
        let clips = await calls.clips
        #expect(clips.count == 2)
        // The first decode purged the window to 2 s before the held segment; the second decodes from "b"'s end (9 s), 7 s into what is left.
        #expect(clips.last == [7])
        await loop.cancel()
        _ = await run.value
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
        #expect(text?.contains("can't stream") == true, "\(text ?? "nil")")
    }

    @Test("the loop is configured per engine")
    func configurationPerEngine() {
        let whisper = StreamingTranscriptionSession.loopConfiguration(
            engine: .whisperKit, wantsConfirmedAudio: false, waitsForModelOnStop: false
        )
        #expect(whisper.requiredSegmentsForConfirmation == 2)
        #expect(whisper.forceConfirmAfterSeconds == nil)
        #expect(whisper.maxDecodeSeconds == nil)
        let parakeet = parakeetConfiguration()
        #expect(parakeet.requiredSegmentsForConfirmation == 1)
        #expect(parakeet.forceConfirmAfterSeconds == 8)
        #expect(parakeet.maxDecodeSeconds == 15)
    }
}
