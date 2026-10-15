import AVFAudio
import Foundation
import Testing
import ParolaCore
@testable import ParolaSpeech

@Suite("AppleSpeechRenderer")
struct AppleSpeechRendererTests {
    private static func descriptor(
        _ identifier: String,
        language: String = "en-US",
        quality: VoiceDescriptor.Quality = .default
    ) -> VoiceDescriptor {
        VoiceDescriptor(
            identifier: identifier, name: identifier, language: language, quality: quality,
            isNovelty: false, isPersonal: false, family: .standard
        )
    }

    private static let samantha = descriptor("com.apple.voice.compact.en-US.Samantha")

    @Test("the system voice renders from another actor without trapping, and nothing plays")
    func isolationGuard() async throws {
        let renderer = await MainActor.run { AppleSpeechRenderer() }
        let stream = try await renderer.render(
            text: "Hello there.", unitID: 3, voice: .appleAutomatic, language: "en"
        )
        var chunks: [PCMChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        #expect(chunks.reduce(0) { $0 + $1.samples.count } > 0)
        #expect(chunks.allSatisfy { $0.sampleRate > 0 && $0.unitID == 3 })
    }

    @Test("a voice that finishes with no frames twice in a row is marked unusable, and the second render throws")
    @MainActor
    func unusableAfterTwoEmptyRenders() async throws {
        let renderer = AppleSpeechRenderer(
            backend: Self.backend { deliver in deliver([], 0) },
            installed: { [Self.samantha] }
        )
        let voice = try #require(VoiceID.apple(identifier: Self.samantha.identifier))
        for try await _ in try await renderer.render(text: "One.", unitID: 0, voice: voice, language: "en") {}
        #expect(renderer.unusableIdentifiers.isEmpty)
        await #expect(throws: AppleSpeechRenderer.Failure.voiceUnusable(identifier: Self.samantha.identifier)) {
            for try await _ in try await renderer.render(text: "Two.", unitID: 1, voice: voice, language: "en") {}
        }
        #expect(renderer.unusableIdentifiers == [Self.samantha.identifier])
    }

    @Test("a voice that produces frames is never marked, and a good render resets the count")
    @MainActor
    func framesKeepAVoiceUsable() async throws {
        let produced = Counter()
        let renderer = AppleSpeechRenderer(
            backend: Self.backend { deliver in
                if produced.next() % 2 == 0 { deliver([0.1, 0.2, 0.3], 22050) }
                deliver([], 0)
            },
            installed: { [Self.samantha] }
        )
        let voice = try #require(VoiceID.apple(identifier: Self.samantha.identifier))
        for index in 0..<6 {
            var samples = 0
            for try await chunk in try await renderer.render(text: "Hi.", unitID: index, voice: voice, language: "en") {
                samples += chunk.samples.count
            }
            #expect(samples == (index % 2 == 0 ? 3 : 0))
        }
        #expect(renderer.unusableIdentifiers.isEmpty)
    }

    @Test("a prewarm that yields nothing never counts against a voice")
    @MainActor
    func prewarmDoesNotMark() async throws {
        let renderer = AppleSpeechRenderer(
            backend: Self.backend { deliver in deliver([], 0) },
            installed: { [Self.samantha] }
        )
        for _ in 0..<3 { try await renderer.prewarm(voice: .appleAutomatic, language: "en") }
        #expect(renderer.unusableIdentifiers.isEmpty)
    }

    @Test("cancel stops the synthesizer and ends the stream")
    @MainActor
    func cancelStops() async throws {
        let stops = Counter()
        let renderer = AppleSpeechRenderer(
            backend: AppleSpeechRenderer.Backend(write: { _, _ in }, stop: { _ = stops.next() }),
            installed: { [Self.samantha] }
        )
        let stream = try await renderer.render(text: "Wait.", unitID: 0, voice: .appleAutomatic, language: "en")
        await renderer.cancel()
        for try await _ in stream {}
        #expect(stops.value == 1)
    }

    @Test("apple:auto with no installed voice for the language throws noVoice")
    func noVoice() {
        #expect(throws: AppleSpeechRenderer.Failure.noVoice(language: "it")) {
            try AppleSpeechRenderer.resolveIdentifier(
                for: .appleAutomatic, language: "it", installed: [Self.samantha], unusable: [], preferredRegions: []
            )
        }
        #expect(throws: AppleSpeechRenderer.Failure.noVoice(language: "en")) {
            try AppleSpeechRenderer.resolveIdentifier(
                for: .appleAutomatic, language: "en", installed: [], unusable: [], preferredRegions: []
            )
        }
    }

    @Test("apple:auto skips unusable voices and prefers the better quality")
    func autoRanking() throws {
        let premium = Self.descriptor("com.apple.voice.premium.en-US.Zoe", quality: .premium)
        let installed = [Self.samantha, premium]
        let first = try AppleSpeechRenderer.resolveIdentifier(
            for: .appleAutomatic, language: "en", installed: installed, unusable: [], preferredRegions: ["US"]
        )
        #expect(first == premium.identifier)
        let second = try AppleSpeechRenderer.resolveIdentifier(
            for: .appleAutomatic, language: "en", installed: installed, unusable: [premium.identifier],
            preferredRegions: ["US"]
        )
        #expect(second == Self.samantha.identifier)
    }

    @Test("an explicit voice resolves to its identifier, and a neural voice is refused")
    func explicitVoices() throws {
        let explicit = try #require(VoiceID.apple(identifier: "com.apple.voice.compact.it-IT.Alice"))
        #expect(
            try AppleSpeechRenderer.resolveIdentifier(
                for: explicit, language: "it", installed: [], unusable: [], preferredRegions: []
            ) == "com.apple.voice.compact.it-IT.Alice"
        )
        let neural = try #require(VoiceID.neural(pack: "supertonic-3", voice: "F1"))
        #expect(throws: AppleSpeechRenderer.Failure.notAnAppleVoice) {
            try AppleSpeechRenderer.resolveIdentifier(
                for: neural, language: "en", installed: [], unusable: [], preferredRegions: []
            )
        }
    }

    @Test("voice families follow the identifier namespace", arguments: [
        ("com.apple.eloquence.en-US.Eddy", VoiceDescriptor.Family.eloquence),
        ("com.apple.speech.synthesis.voice.Fred", .macinTalk),
        ("com.apple.speech.synthesis.voice.Albert", .macinTalk),
        ("com.apple.voice.compact.en-US.Samantha", .standard),
        ("com.apple.voice.premium.en-US.Zoe", .standard),
        ("com.apple.ttsbundle.Samantha-compact", .standard),
    ])
    func families(identifier: String, family: VoiceDescriptor.Family) {
        #expect(AppleSpeechRenderer.family(forIdentifier: identifier) == family)
    }

    @Test("Int16 and Float32 buffers both come out as Float32 mono at the buffer's rate")
    func bufferConversion() throws {
        let intFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: false))
        let ints = try #require(AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 3))
        ints.frameLength = 3
        ints.int16ChannelData?[0][0] = 16384
        ints.int16ChannelData?[0][1] = -16384
        ints.int16ChannelData?[0][2] = 0
        #expect(AppleSpeechRenderer.monoSamples(of: ints) == [0.5, -0.5, 0])

        let floatFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false))
        let floats = try #require(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 2))
        floats.frameLength = 2
        floats.floatChannelData?[0][0] = 0.25
        floats.floatChannelData?[0][1] = -0.25
        #expect(AppleSpeechRenderer.monoSamples(of: floats) == [0.25, -0.25])
    }

    private final class Counter: Sendable {
        private let count = Awaitable(0)
        var value: Int { count.value }

        func next() -> Int {
            let current = count.value
            count.increment()
            return current
        }
    }

    @MainActor
    private static func backend(
        _ script: @escaping @Sendable (AppleSpeechRenderer.Delivery) -> Void
    ) -> AppleSpeechRenderer.Backend {
        AppleSpeechRenderer.Backend(write: { _, deliver in script(deliver) }, stop: {})
    }
}
