import Foundation
import ParolaCore

/// A renderer for tests and the `--test-mode` sandbox. It emits silence, or a sine tone, sized from the
/// text length and paced by an injected clock. `holdStart()` parks later renders before their first chunk
/// until `releaseStart()`, and `holdPrewarm()` keeps later prewarms running until `releasePrewarm()`. It
/// records misuse (empty text, overlapping work) instead of trapping, so a test can assert its caller
/// never breaks the `SpeechRenderer` preconditions.
public actor MockSpeechRenderer: SpeechRenderer {
    public struct Rendered: Hashable, Sendable {
        public let unitID: Int
        public let text: String
        public let voice: VoiceID
        public let language: String

        public init(unitID: Int, text: String, voice: VoiceID, language: String) {
            self.unitID = unitID
            self.text = text
            self.voice = voice
            self.language = language
        }
    }

    public enum Violation: Hashable, Sendable {
        case emptyText(unitID: Int)
        case concurrentRender(unitID: Int)
        case concurrentPrewarm
    }

    public enum Event: Hashable, Sendable {
        case started(unitID: Int)
        case held(unitID: Int)
        case ended(unitID: Int)
        case prewarmHeld
        case prewarmEnded
    }

    public typealias Observer = @Sendable (Event) -> Void

    public struct Failure: Error, Hashable {
        public let unitID: Int

        public init(unitID: Int) {
            self.unitID = unitID
        }
    }

    public static let toneAmplitude = 0.1

    public nonisolated let engine: SpeechEngineKind
    public nonisolated let capabilities: SpeechRendererCapabilities

    public private(set) var rendered: [Rendered] = []
    public private(set) var prewarmed: [VoiceID] = []
    public private(set) var violations: [Violation] = []
    public private(set) var peakConcurrentRenders = 0
    public private(set) var cancelCount = 0
    public private(set) var failAtUnit: Int?

    private let clock: any Clock<Duration>
    private let sampleRate: Double
    private let secondsPerCharacter: Double
    private let realTimeFactor: Double
    private let chunkSamples: Int
    private let toneFrequency: Double?
    private let observer: Observer?

    private enum Gate {
        case start
        case prewarm
    }

    private struct Parked {
        let gate: Gate
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeRenders = 0
    private var holding: Set<Gate> = []
    private var parked: [UUID: Parked] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]

    public init(
        engine: SpeechEngineKind = .apple,
        capabilities: SpeechRendererCapabilities = SpeechRendererCapabilities(
            languages: [], expandsNumbers: true, usesNeuralEngine: false, nominalRTF: 0, maxUnitChars: 400
        ),
        clock: any Clock<Duration> = ContinuousClock(),
        sampleRate: Double = 24_000,
        secondsPerCharacter: Double = 0.06,
        realTimeFactor: Double = 0,
        chunkSeconds: Double = 0.25,
        toneFrequency: Double? = nil,
        failAtUnit: Int? = nil,
        observer: Observer? = nil
    ) {
        self.engine = engine
        self.capabilities = capabilities
        self.clock = clock
        self.sampleRate = sampleRate
        self.secondsPerCharacter = secondsPerCharacter
        self.realTimeFactor = realTimeFactor
        self.chunkSamples = max(1, Int((chunkSeconds * sampleRate).rounded()))
        self.toneFrequency = toneFrequency
        self.failAtUnit = failAtUnit
        self.observer = observer
    }

    public func setFailAtUnit(_ unitID: Int?) {
        failAtUnit = unitID
    }

    public func holdStart() {
        holding.insert(.start)
    }

    public func releaseStart() {
        release(.start)
    }

    public func holdPrewarm() {
        holding.insert(.prewarm)
    }

    public func releasePrewarm() {
        release(.prewarm)
    }

    public func render(
        text: String,
        unitID: Int,
        voice: VoiceID,
        language: String
    ) async throws -> AsyncThrowingStream<PCMChunk, any Error> {
        rendered.append(Rendered(unitID: unitID, text: text, voice: voice, language: language))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.emptyText(unitID: unitID))
        }
        if activeRenders > 0 {
            violations.append(.concurrentRender(unitID: unitID))
        }
        activeRenders += 1
        peakConcurrentRenders = max(peakConcurrentRenders, activeRenders)
        observer?(.started(unitID: unitID))

        let totalSamples = Int((Double(text.count) * secondsPerCharacter * sampleRate).rounded())
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self, throwing: (any Error).self)
        let id = UUID()
        let task = Task {
            await produce(id: id, unitID: unitID, totalSamples: totalSamples, into: continuation)
        }
        running[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel() async {
        cancelCount += 1
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    public func prewarm(voice: VoiceID, language: String) async throws {
        prewarmed.append(voice)
        if activeRenders > 0 {
            violations.append(.concurrentPrewarm)
        }
        activeRenders += 1
        peakConcurrentRenders = max(peakConcurrentRenders, activeRenders)
        defer {
            activeRenders -= 1
            observer?(.prewarmEnded)
        }
        if holding.contains(.prewarm) {
            await park(at: .prewarm, id: UUID(), announcing: .prewarmHeld)
        }
        try Task.checkCancellation()
    }

    private func produce(
        id: UUID,
        unitID: Int,
        totalSamples: Int,
        into continuation: AsyncThrowingStream<PCMChunk, any Error>.Continuation
    ) async {
        defer {
            running[id] = nil
            activeRenders -= 1
            observer?(.ended(unitID: unitID))
        }
        if holding.contains(.start) {
            await park(at: .start, id: id, announcing: .held(unitID: unitID))
        }
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        if unitID == failAtUnit {
            continuation.finish(throwing: Failure(unitID: unitID))
            return
        }
        var produced = 0
        while produced < totalSamples {
            let count = min(chunkSamples, totalSamples - produced)
            let chunk = PCMChunk(unitID: unitID, samples: samples(from: produced, count: count), sampleRate: sampleRate)
            do {
                if realTimeFactor > 0 {
                    try await clock.sleep(for: .seconds(chunk.duration * realTimeFactor), tolerance: nil)
                }
                try Task.checkCancellation()
            } catch {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(chunk)
            produced += count
        }
        continuation.finish()
    }

    private func park(at gate: Gate, id: UUID, announcing event: Event) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard holding.contains(gate), !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                parked[id] = Parked(gate: gate, continuation: continuation)
                observer?(event)
            }
        } onCancel: {
            Task { await self.unpark(id) }
        }
    }

    private func unpark(_ id: UUID) {
        parked.removeValue(forKey: id)?.continuation.resume()
    }

    private func release(_ gate: Gate) {
        holding.remove(gate)
        let ids = parked.filter { $0.value.gate == gate }.map(\.key)
        for id in ids { unpark(id) }
    }

    private func samples(from offset: Int, count: Int) -> [Float] {
        guard let toneFrequency else { return [Float](repeating: 0, count: count) }
        let step = 2 * Double.pi * toneFrequency / sampleRate
        return (offset..<(offset + count)).map { index in
            Float(Self.toneAmplitude * sin(step * Double(index)))
        }
    }
}
