import Foundation
import AVFoundation

/// Provides audio to the transcription engine as a decoded file URL.
///
/// For files this is the original path; for live capture (mic, system audio)
/// it's a temporary WAV the source wrote to disk.
public protocol AudioSource: Sendable {
    /// Resolves the URL to a file ready for transcription. May start recording.
    func prepare() async throws -> URL

    /// Stops any in-flight capture. Safe to call multiple times.
    func cancel() async

    /// Best-effort duration in seconds. Returns nil for live sources or when probing fails.
    func estimatedDuration() async -> Double?
}

public extension AudioSource {
    func estimatedDuration() async -> Double? { nil }
}

enum AudioLevel {
    /// Maps a PCM buffer's RMS energy to a 0...1 amplitude (dB-normalised over a -55 dB floor).
    static func normalised(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channels[0]
        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumSquares += sample * sample
        }
        let rms = sqrtf(sumSquares / Float(frameCount))
        let minDb: Float = -55
        let db = 20 * log10f(max(rms, 1e-7))
        let clamped = max(minDb, min(0, db))
        return (clamped - minDb) / -minDb
    }
}
