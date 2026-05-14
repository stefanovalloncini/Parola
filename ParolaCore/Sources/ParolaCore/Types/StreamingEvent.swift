import Foundation

/// Events emitted by ``StreamingTranscriptionSession`` while live transcription is running.
public enum StreamingEvent: Sendable {
    /// Best-current text from the active window. Replaces any previous partial.
    case partial(text: String)
    /// A segment that WhisperKit has locked in. Appended to the running transcript.
    case confirmed(TranscriptSegment)
    /// Whisper's per-buffer voice-activity flag flipped to true / false (useful for UI).
    case voiceActivity(active: Bool)
    /// A non-fatal recoverable error.
    case warning(String)
    /// A fatal error. The stream will close after this.
    case failed(String)
    /// Final transcript after `stop()`. Always the last event before the stream ends.
    case finished(Transcript)
}
