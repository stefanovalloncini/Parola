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
}
