import Foundation
import AVFoundation

/// AudioSource backed by an on-disk WAV fixture. Used by the agent platform to
/// drive recording flows in test mode without real microphone or screen capture.
///
/// `start()` paces the level meter's readings via the injected clock so tests that
/// install a `TestClock` can advance time deterministically. `prepare()` returns
/// the fixture URL so transcription can read it like any other file.
public actor FixtureAudioSource: LiveAudioSource {
    private let fixtureURL: URL
    private let sleeper: @Sendable (Int) async throws -> Void
    private var started = false
    private var paused = false
    private var paceTask: Task<Void, Never>?
    public nonisolated let levelMeter = LevelMeter()

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

    public func start() async throws {
        guard !started else { return }
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw ParolaError.audioLoadFailed(fixtureURL, underlying: "fixture not found")
        }
        started = true
        paused = false
        paceTask?.cancel()
        let sleeper = sleeper
        let url = fixtureURL
        paceTask = Task { [weak self] in
            await self?.paceLevels(from: url, sleeper: sleeper)
        }
    }

    private func paceLevels(from url: URL, sleeper: @Sendable (Int) async throws -> Void) async {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.05)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
        let frameDurationMs = max(1, Int(Double(chunkFrames) * 1000 / format.sampleRate))

        while file.framePosition < file.length {
            if Task.isCancelled { return }
            if paused {
                try? await sleeper(frameDurationMs)
                continue
            }
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                return
            }
            if buffer.frameLength == 0 { return }
            levelMeter.record(AudioLevel.normalised(of: buffer))
            try? await sleeper(frameDurationMs)
        }
    }

    public func prepare() async throws -> URL {
        guard started else {
            throw ParolaError.captureUnavailable("fixture audio source not started")
        }
        paceTask?.cancel()
        paceTask = nil
        levelMeter.reset()
        started = false
        return fixtureURL
    }

    public func cancel() async {
        started = false
        paceTask?.cancel()
        paceTask = nil
        levelMeter.reset()
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
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
}
