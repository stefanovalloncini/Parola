import AVFoundation
import Foundation
import os

/// Appends streamed mono Float32 samples to a temporary WAV file as they arrive,
/// so a live recording never accumulates in memory.
final class StreamingAudioPersister: Sendable {
    private static let tapChunksPerMinuteAt48kHz = 1800
    private static let maxBufferedChunks = 3 * tapChunksPerMinuteAt48kHz

    let url: URL
    private let continuation: AsyncStream<[Float]>.Continuation
    private let writerTask: Task<URL?, Never>
    private let dropped = OSAllocatedUnfairLock(initialState: false)

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-recording-\(UUID().uuidString).wav")
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else { return nil }

        self.url = url
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self,
            bufferingPolicy: .bufferingNewest(Self.maxBufferedChunks)
        )
        self.continuation = continuation
        let audioFile = file
        writerTask = Task.detached(priority: .utility) {
            var wroteAny = false
            var failed = false
            for await samples in stream {
                guard !failed, !samples.isEmpty else { continue }
                if Self.append(samples, to: audioFile, format: format) {
                    wroteAny = true
                } else {
                    failed = true
                }
            }
            guard wroteAny, !failed else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url
        }
    }

    /// True when the writer fell behind: the take has gaps but everything else is still on disk.
    var droppedAudio: Bool {
        dropped.withLock { $0 }
    }

    func append(_ samples: [Float]) {
        if case .dropped = continuation.yield(samples) {
            noteDrop()
        }
    }

    func noteDrop() {
        dropped.withLock { $0 = true }
    }

    /// Finishes the WAV and returns its URL, or nil if nothing was written or a write failed.
    func finish() async -> URL? {
        continuation.finish()
        return await writerTask.value
    }

    /// Finishes and deletes the file; for teardown paths that won't use the recording.
    func discard() async {
        if let url = await finish() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func append(_ samples: [Float], to file: AVAudioFile, format: AVAudioFormat) -> Bool {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }
}
