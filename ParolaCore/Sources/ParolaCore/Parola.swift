import Foundation

/// ParolaCore is the engine for the Parola transcription app and CLI.
///
/// Headline types:
/// - ``TranscriptionSession`` — top-level orchestrator.
/// - ``ModelStore`` — model registry + on-disk cache.
/// - ``FileAudioSource`` / ``MicAudioSource`` / ``SystemAudioSource`` — audio inputs.
/// - ``Transcript`` and ``TranscriptSegment`` — output value types.
/// - ``Exporters`` — render a `Transcript` to txt / srt / vtt / json.
public enum Parola {
    public static let version = "0.1.0"
}
