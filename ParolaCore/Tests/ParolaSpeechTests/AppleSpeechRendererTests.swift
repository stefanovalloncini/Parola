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
        let installed = await MainActor.run { AppleSpeechRenderer.installedVoices() }
        let pinned = installed.first { $0.identifier == "com.apple.voice.compact.en-US.Samantha" }
            ?? installed.first { !$0.isNovelty && !$0.isPersonal && $0.family == .standard }
        guard let pinned, let voice = VoiceID.apple(identifier: pinned.identifier) else {
            Issue.record("no Apple voice is installed on this Mac")
            return
        }
        let renderer = await MainActor.run { AppleSpeechRenderer() }
        let stream = try await renderer.render(
            text: "Hello there.", unitID: 3, voice: voice, language: pinned.language
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

    @Test("cancel replaces the synthesizer, drops late buffers, and the next render writes on the fresh one")
    @MainActor
    func cancelReplacesSynthesizer() async throws {
        let synthesizers = FakeSynthesizers()
        let renderer = AppleSpeechRenderer(backend: synthesizers.backend, installed: { [Self.samantha] })
        let first = try await renderer.render(text: "Long.", unitID: 0, voice: .appleAutomatic, language: "en")
        await renderer.cancel()
        #expect(synthesizers.generation == 1)
        await #expect(throws: CancellationError.self) { for try await _ in first {} }

        let second = try await renderer.render(text: "Next.", unitID: 1, voice: .appleAutomatic, language: "en")
        #expect(synthesizers.writes.map(\.generation) == [0, 1])
        synthesizers.writes[0].deliver([0.9], 22050)
        synthesizers.writes[1].deliver([0.1, 0.2], 22050)
        synthesizers.writes[1].deliver([], 0)
        var received: [Float] = []
        for try await chunk in second { received += chunk.samples }
        #expect(received == [0.1, 0.2])
    }

    @Test("a second render started over a running one ends the first stream")
    @MainActor
    func secondStartFinishesFirst() async throws {
        let synthesizers = FakeSynthesizers()
        let renderer = AppleSpeechRenderer(backend: synthesizers.backend, installed: { [Self.samantha] })
        let first = try await renderer.render(text: "One.", unitID: 0, voice: .appleAutomatic, language: "en")
        _ = try await renderer.render(text: "Two.", unitID: 1, voice: .appleAutomatic, language: "en")
        await #expect(throws: CancellationError.self) { for try await _ in first {} }
    }

    @Test("the voice list is read once, auto is resolved once, and an explicit voice never reads it")
    @MainActor
    func inventoryCached() async throws {
        let reads = Counter()
        let renderer = AppleSpeechRenderer(
            backend: Self.backend { deliver in deliver([0.5], 22050); deliver([], 0) },
            installed: { _ = reads.next(); return [Self.samantha] }
        )
        #expect(reads.value == 1)
        let explicit = try #require(VoiceID.apple(identifier: Self.samantha.identifier))
        for index in 0..<3 {
            for try await _ in try await renderer.render(text: "A.", unitID: index, voice: explicit, language: "en") {}
            for try await _ in try await renderer.render(text: "A.", unitID: index, voice: .appleAutomatic, language: "en") {}
        }
        #expect(reads.value == 1)
        renderer.refreshVoices()
        #expect(reads.value == 2)
    }

    @Test("a voice marked unusable leaves the apple:auto choice, and the next render uses the second voice")
    @MainActor
    func unusableLeavesAutoChoice() async throws {
        let real = AppleSpeechRenderer.installedVoices()
            .filter { !$0.isNovelty && !$0.isPersonal && $0.language.hasPrefix("en") }
        try #require(real.count >= 2)
        var top = real[0]
        top.quality = .premium
        var second = real[1]
        second.quality = .default
        let written = Awaitable<[String]>([])
        let renderer = AppleSpeechRenderer(
            backend: AppleSpeechRenderer.Backend(
                write: { utterance, deliver in
                    let identifier = utterance.voice?.identifier ?? ""
                    written.update { $0.append(identifier) }
                    deliver([], 0)
                },
                reset: {}
            ),
            installed: { [top, second] }
        )
        for unit in 0..<2 {
            let stream = try await renderer.render(text: "A.", unitID: unit, voice: .appleAutomatic, language: "en")
            _ = try? await { for try await _ in stream {} }()
        }
        #expect(renderer.unusableIdentifiers == [top.identifier])
        for try await _ in try await renderer.render(text: "A.", unitID: 2, voice: .appleAutomatic, language: "en") {}
        #expect(written.value == [top.identifier, top.identifier, second.identifier])
    }

    @Test("a refresh changes what apple:auto picks")
    @MainActor
    func refreshRepicks() async throws {
        let installed = Awaitable<[VoiceDescriptor]>([])
        let renderer = AppleSpeechRenderer(
            backend: Self.backend { deliver in deliver([], 0) },
            installed: { installed.value }
        )
        await #expect(throws: AppleSpeechRenderer.Failure.noVoice(language: "en")) {
            _ = try await renderer.render(text: "A.", unitID: 0, voice: .appleAutomatic, language: "en")
        }
        installed.update { $0 = [Self.samantha] }
        await #expect(throws: AppleSpeechRenderer.Failure.noVoice(language: "en")) {
            _ = try await renderer.render(text: "A.", unitID: 0, voice: .appleAutomatic, language: "en")
        }
        renderer.refreshVoices()
        _ = try await renderer.render(text: "A.", unitID: 0, voice: .appleAutomatic, language: "en")
    }

    @Test("a buffer in an unknown format is not a sample run")
    func unknownFormat() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 22050, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        #expect(AppleSpeechRenderer.monoSamples(of: buffer) == nil)
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
    private final class FakeSynthesizers {
        struct Write {
            let generation: Int
            let deliver: AppleSpeechRenderer.Delivery
        }

        private(set) var generation = 0
        private(set) var writes: [Write] = []

        var backend: AppleSpeechRenderer.Backend {
            AppleSpeechRenderer.Backend(
                write: { [self] _, deliver in writes.append(Write(generation: generation, deliver: deliver)) },
                reset: { [self] in generation += 1 }
            )
        }
    }

    @MainActor
    private static func backend(
        _ script: @escaping @Sendable (AppleSpeechRenderer.Delivery) -> Void
    ) -> AppleSpeechRenderer.Backend {
        AppleSpeechRenderer.Backend(write: { _, deliver in script(deliver) }, reset: {})
    }
}
