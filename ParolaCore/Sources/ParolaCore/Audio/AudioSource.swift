import Foundation

/// Provides audio to the transcription engine as a decoded file URL.
///
/// For files this is the original path; for live capture (mic, system audio)
/// it's a temporary WAV the source wrote to disk.
public protocol AudioSource: Sendable {
    /// Resolves the URL to a file ready for transcription. May start recording.
    func prepare() async throws -> URL

    /// Stops any in-flight capture. Safe to call multiple times.
    func cancel() async
}
