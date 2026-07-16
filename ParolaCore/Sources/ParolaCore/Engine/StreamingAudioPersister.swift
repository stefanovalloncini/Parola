import AVFoundation
import Foundation

/// Appends streamed mono Float32 samples to a temporary WAV file as they arrive,
/// so a live recording never accumulates in memory.
final class StreamingAudioPersister: Sendable {
    let url: URL
    private let continuation: AsyncStream<[Float]>.Continuation
    private let writerTask: Task<URL?, Never>

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
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
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

    func append(_ samples: [Float]) {
        continuation.yield(samples)
    }

    /// Finishes the WAV and returns its URL, or nil if nothing was written.
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
