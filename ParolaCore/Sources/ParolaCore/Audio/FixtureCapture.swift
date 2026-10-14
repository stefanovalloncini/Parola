import Foundation
import AVFoundation
import os
@preconcurrency import WhisperKit

/// Streams an on-disk WAV as 16 kHz mono chunks paced by a clock: the test-mode stand-in for system and app capture.
public final class FixtureCapture: Sendable {
    public static let chunkDuration: Duration = .milliseconds(100)

    private let samples: [Float]
    private let clock: any Clock<Duration>
    private let chunkSamples: Int
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init(fixtureURL: URL, clock: any Clock<Duration> = ContinuousClock()) throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw ParolaError.audioLoadFailed(fixtureURL, underlying: "fixture not found")
        }
        self.samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixtureURL.path)
        self.clock = clock
        self.chunkSamples = WhisperKit.sampleRate / 10
    }

    init(samples: [Float], clock: any Clock<Duration>) {
        self.samples = samples
        self.clock = clock
        self.chunkSamples = WhisperKit.sampleRate / 10
    }

    /// Delivers the first chunk now and chunk k at k × `chunkDuration`, until the file ends or `stop()`; `onEnd` runs once when the file ends, never after a stop.
    public func start(onBuffer: @escaping @Sendable ([Float]) -> Void, onEnd: (@Sendable () -> Void)? = nil) {
        let samples = samples
        let clock = clock
        let size = chunkSamples
        let running = Task {
            if await Self.deliver(samples, in: size, on: clock, to: onBuffer) { onEnd?() }
        }
        task.withLock { current in
            current?.cancel()
            current = running
        }
    }

    // Absolute deadlines, so a late wake is made up by the next chunk instead of pushing the whole file back.
    private static func deliver<C: Clock<Duration>>(
        _ samples: [Float], in size: Int, on clock: C, to onBuffer: @Sendable ([Float]) -> Void
    ) async -> Bool {
        let start = clock.now
        var offset = 0
        var index = 0
        while offset < samples.count, !Task.isCancelled {
            let end = min(offset + size, samples.count)
            onBuffer(Array(samples[offset..<end]))
            offset = end
            index += 1
            guard offset < samples.count else { return !Task.isCancelled }
            do { try await clock.sleep(until: start.advanced(by: chunkDuration * index), tolerance: .zero) } catch { return false }
        }
        return !Task.isCancelled
    }

    public func stop() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
