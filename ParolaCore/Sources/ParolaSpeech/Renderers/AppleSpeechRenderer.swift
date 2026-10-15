import AVFAudio
import Foundation
import ParolaCore

/// Renders with the Apple voices installed on this Mac through `AVSpeechSynthesizer.write`, which makes
/// buffers without playing them.
// Must stay @MainActor: write()'s ObjC callbacks reach main only on a CFRunLoop host, and a closure
// capturing an actor's self gets a Swift 6 executor check that traps on the first buffer.
@MainActor
public final class AppleSpeechRenderer: SpeechRenderer {
    public enum Failure: Error, Hashable {
        case noVoice(language: String)
        case voiceUnusable(identifier: String)
        case notAnAppleVoice
    }

    typealias Delivery = @Sendable ([Float], Double) -> Void

    struct Backend {
        var write: @MainActor (AVSpeechUtterance, @escaping Delivery) -> Void
        var reset: @MainActor () -> Void
    }

    private struct ActiveRender {
        let id: Int
        let voiceIdentifier: String
        let counts: Bool
        let continuation: AsyncThrowingStream<PCMChunk, any Error>.Continuation
        var frames = 0
    }

    private static let unusableAfterEmptyRenders = 2
    private static let prewarmText = "Ready."

    public nonisolated let engine = SpeechEngineKind.apple
    public nonisolated let capabilities = SpeechRendererCapabilities(
        languages: [], expandsNumbers: true, usesNeuralEngine: false, nominalRTF: 0.02, maxUnitChars: 400
    )

    public private(set) var unusableIdentifiers: Set<String> = []

    private let backend: Backend
    private let readInstalled: @MainActor () -> [VoiceDescriptor]
    private var inventory: [VoiceDescriptor]
    private var autoChoices: [String: String] = [:]
    private var active: ActiveRender?
    private var lastID = 0
    private var emptyRenders: [String: Int] = [:]

    public convenience init() {
        let holder = SynthesizerHolder()
        self.init(
            backend: Backend(
                write: { utterance, deliver in
                    holder.synthesizer.write(
                        utterance, toBufferCallback: Self.bufferCallback(deliver), toMarkerCallback: { _ in }
                    )
                },
                reset: { holder.synthesizer = AVSpeechSynthesizer() }
            ),
            installed: { Self.installedVoices() }
        )
    }

    init(backend: Backend, installed: @escaping @MainActor () -> [VoiceDescriptor]) {
        self.backend = backend
        self.readInstalled = installed
        self.inventory = installed()
    }

    public func refreshVoices() {
        inventory = readInstalled()
        autoChoices.removeAll()
    }

    @MainActor private final class SynthesizerHolder {
        var synthesizer = AVSpeechSynthesizer()
    }

    // MARK: - Voices

    public static func installedVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map(descriptor(for:))
    }

    static func descriptor(for voice: AVSpeechSynthesisVoice) -> VoiceDescriptor {
        VoiceDescriptor(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality(of: voice),
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
            family: family(forIdentifier: voice.identifier)
        )
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> VoiceDescriptor.Quality {
        switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .default
        }
    }

    // Eloquence is com.apple.eloquence.*, MacinTalk is com.apple.speech.synthesis.voice.*, the rest is standard.
    nonisolated static func family(forIdentifier identifier: String) -> VoiceDescriptor.Family {
        let lowered = identifier.lowercased()
        if lowered.hasPrefix("com.apple.eloquence.") { return .eloquence }
        if lowered.hasPrefix("com.apple.speech.synthesis.voice.") { return .macinTalk }
        return .standard
    }

    nonisolated static func resolveIdentifier(
        for voice: VoiceID,
        language: String,
        installed: [VoiceDescriptor],
        unusable: Set<String>,
        preferredRegions: [String]
    ) throws -> String {
        switch voice.kind {
        case .appleAutomatic:
            guard let best = AppleVoiceRanking.best(
                installed, forLanguage: language, preferredRegions: preferredRegions, unusable: unusable
            ) else { throw Failure.noVoice(language: language) }
            return best.identifier
        case .apple(let identifier):
            guard !unusable.contains(identifier) else { throw Failure.voiceUnusable(identifier: identifier) }
            return identifier
        case .neural:
            throw Failure.notAnAppleVoice
        }
    }

    private func utterance(text: String, voice: VoiceID, language: String) throws -> (AVSpeechUtterance, String) {
        let regions = Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).region?.identifier }
        let identifier: String
        if case .appleAutomatic = voice.kind {
            let key = "\(voice.rawValue)|\(language)"
            if let chosen = autoChoices[key] {
                identifier = chosen
            } else {
                identifier = try Self.resolveIdentifier(
                    for: voice, language: language, installed: inventory, unusable: unusableIdentifiers,
                    preferredRegions: regions
                )
                autoChoices[key] = identifier
            }
        } else {
            identifier = try Self.resolveIdentifier(
                for: voice, language: language, installed: [], unusable: unusableIdentifiers,
                preferredRegions: regions
            )
        }
        guard let resolved = AVSpeechSynthesisVoice(identifier: identifier) else {
            throw Failure.noVoice(language: language)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolved
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return (utterance, identifier)
    }

    // MARK: - SpeechRenderer

    public func render(
        text: String,
        unitID: Int,
        voice: VoiceID,
        language: String
    ) async throws -> AsyncThrowingStream<PCMChunk, any Error> {
        try start(text: text, unitID: unitID, voice: voice, language: language, counts: true)
    }

    public func cancel() async {
        guard let active else { return }
        self.active = nil
        backend.reset()
        active.continuation.finish(throwing: CancellationError())
    }

    public func prewarm(voice: VoiceID, language: String) async throws {
        let stream = try start(text: Self.prewarmText, unitID: -1, voice: voice, language: language, counts: false)
        for try await _ in stream {}
    }

    private func start(
        text: String,
        unitID: Int,
        voice: VoiceID,
        language: String,
        counts: Bool
    ) throws -> AsyncThrowingStream<PCMChunk, any Error> {
        let (utterance, identifier) = try utterance(text: text, voice: voice, language: language)
        lastID += 1
        let id = lastID
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self, throwing: (any Error).self)
        if let previous = active {
            previous.continuation.finish(throwing: CancellationError())
        }
        active = ActiveRender(id: id, voiceIdentifier: identifier, counts: counts, continuation: continuation)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in await self?.cancelRender(id) }
        }
        backend.write(utterance) { samples, sampleRate in
            MainActor.assumeIsolated { [weak self] in
                self?.receive(samples, sampleRate: sampleRate, id: id, unitID: unitID)
            }
        }
        return stream
    }

    private func cancelRender(_ id: Int) async {
        guard active?.id == id else { return }
        await cancel()
    }

    private func receive(_ samples: [Float], sampleRate: Double, id: Int, unitID: Int) {
        guard var current = active, current.id == id else { return }
        if samples.isEmpty {
            active = nil
            finish(current)
            return
        }
        current.frames += samples.count
        active = current
        current.continuation.yield(PCMChunk(unitID: unitID, samples: samples, sampleRate: sampleRate))
    }

    private func finish(_ render: ActiveRender) {
        guard render.counts else {
            render.continuation.finish()
            return
        }
        guard render.frames == 0 else {
            emptyRenders[render.voiceIdentifier] = nil
            render.continuation.finish()
            return
        }
        let empty = (emptyRenders[render.voiceIdentifier] ?? 0) + 1
        emptyRenders[render.voiceIdentifier] = empty
        guard empty >= Self.unusableAfterEmptyRenders else {
            render.continuation.finish()
            return
        }
        unusableIdentifiers.insert(render.voiceIdentifier)
        autoChoices.removeAll()
        ParolaLog.error(
            .readAloud, "an Apple voice produced no audio twice and is skipped",
            [.engine: .safe(SpeechEngineKind.apple)]
        )
        render.continuation.finish(throwing: Failure.voiceUnusable(identifier: render.voiceIdentifier))
    }

    // MARK: - Buffers

    nonisolated private static func bufferCallback(_ deliver: @escaping Delivery) -> @Sendable (AVAudioBuffer) -> Void {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                deliver([], 0)
                return
            }
            guard let samples = monoSamples(of: pcm) else {
                ParolaLog.error(
                    .readAloud, "an Apple voice delivered a buffer in a format Parola can't read",
                    [.engine: .safe(SpeechEngineKind.apple)]
                )
                deliver([], 0)
                return
            }
            deliver(samples, pcm.format.sampleRate)
        }
    }

    nonisolated static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float]? {
        let count = Int(buffer.frameLength)
        if let channels = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channels[0], count: count))
        }
        if let channels = buffer.int16ChannelData {
            return UnsafeBufferPointer(start: channels[0], count: count).map { Float($0) / 32768 }
        }
        if let channels = buffer.int32ChannelData {
            return UnsafeBufferPointer(start: channels[0], count: count).map { Float($0) / 2147483648 }
        }
        return nil
    }
}
