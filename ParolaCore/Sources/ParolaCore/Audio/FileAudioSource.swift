import Foundation
import AVFoundation

/// Audio source backed by a file on disk. WhisperKit decodes it directly via AVFoundation,
/// so we only validate the file is reachable and report its duration.
public struct FileAudioSource: AudioSource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func prepare() async throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParolaError.audioLoadFailed(url, underlying: "file does not exist")
        }
        return url
    }

    public func cancel() async {}

    public func estimatedDuration() async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let dur = try await asset.load(.duration)
            return CMTimeGetSeconds(dur)
        } catch {
            return nil
        }
    }

    /// Reads the file's duration synchronously from its header — blocking I/O, never call on the main actor. Returns nil when the file is
    /// unreadable or not a decodable audio track, in which case fall back to `estimatedDuration()`.
    public func synchronousDuration() -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let seconds = Double(file.length) / sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
