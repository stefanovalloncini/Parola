import Foundation
@preconcurrency import AVFoundation

/// AudioSource backed by an on-disk WAV fixture. Used by the agent platform to
/// drive recording flows in test mode without real microphone or screen capture.
///
/// `start()` paces emitted level samples via the injected clock so tests that
/// install a `TestClock` can advance time deterministically. `prepare()` returns
/// the fixture URL so transcription can read it like any other file.
public actor FixtureAudioSource: LiveAudioSource {
    private let fixtureURL: URL
    private let sleeper: @Sendable (Int) async throws -> Void
    private var started = false
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var paceTask: Task<Void, Never>?

    public init<C: Clock>(fixtureURL: URL, clock: C) where C.Duration == Duration {
        self.fixtureURL = fixtureURL
        self.sleeper = { ms in
            try await Task.sleep(for: .milliseconds(ms), clock: clock)
        }
    }

    public static func make(fixtureURL: URL, clock: any Clock<Duration>) -> FixtureAudioSource {
        func _make<C: Clock>(_ clock: C) -> FixtureAudioSource where C.Duration == Duration {
            FixtureAudioSource(fixtureURL: fixtureURL, clock: clock)
        }
        return _make(clock)
    }

    public func levels() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            levelContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeLevelContinuation(id) }
            }
        }
    }

    private func removeLevelContinuation(_ id: UUID) {
        levelContinuations.removeValue(forKey: id)
    }

    public func start() async throws {
        guard !started else { return }
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw ParolaError.audioLoadFailed(fixtureURL, underlying: "fixture not found")
        }
        started = true
        paceTask?.cancel()
        let sleeper = sleeper
        let url = fixtureURL
        paceTask = Task { [weak self] in
            await self?.emitLevels(from: url, sleeper: sleeper)
        }
    }

    private func emitLevels(from url: URL, sleeper: @Sendable (Int) async throws -> Void) async {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.05)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
        let frameDurationMs = max(1, Int(Double(chunkFrames) * 1000 / format.sampleRate))

        while file.framePosition < file.length {
            if Task.isCancelled { return }
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                return
            }
            if buffer.frameLength == 0 { return }
            let level = AudioLevel.normalised(of: buffer)
            emitLevel(level)
            try? await sleeper(frameDurationMs)
        }
    }

    private func emitLevel(_ level: Float) {
        for continuation in levelContinuations.values {
            continuation.yield(level)
        }
    }

    public func prepare() async throws -> URL {
        guard started else {
            throw ParolaError.captureUnavailable("fixture audio source not started")
        }
        paceTask?.cancel()
        paceTask = nil
        finishLevels()
        return fixtureURL
    }

    public func cancel() async {
        started = false
        paceTask?.cancel()
        paceTask = nil
        finishLevels()
    }

    public func estimatedDuration() async -> Double? {
        let asset = AVURLAsset(url: fixtureURL)
        do {
            let dur = try await asset.load(.duration)
            return CMTimeGetSeconds(dur)
        } catch {
            return nil
        }
    }

    private func finishLevels() {
        for continuation in levelContinuations.values {
            continuation.finish()
        }
        levelContinuations.removeAll()
    }
}
