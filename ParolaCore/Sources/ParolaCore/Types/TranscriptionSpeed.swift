import Foundation

/// How much faster than real time a transcription ran: audio seconds over the wall-clock seconds
/// the engine took. Frontends show the multiple ("16×"), never the reciprocal.
public enum TranscriptionSpeed {
    public static func factor(audioSeconds: Double?, transcriptionSeconds: Double?) -> Double? {
        guard let audioSeconds, let transcriptionSeconds,
              audioSeconds.isFinite, transcriptionSeconds.isFinite,
              audioSeconds > 0, transcriptionSeconds > 0
        else { return nil }
        return audioSeconds / transcriptionSeconds
    }

    /// A tenth below ten, whole numbers above it: past 10× the first decimal is noise.
    public static func label(_ factor: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = factor < 10 ? 1 : 0
        let number = factor.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return "\(number)×"
    }

    /// The ratio the other way round, for tooling that asks for it by name. Never shown on its own in the UI.
    public static func realTimeFactor(audioSeconds: Double?, transcriptionSeconds: Double?) -> Double? {
        guard let factor = factor(audioSeconds: audioSeconds, transcriptionSeconds: transcriptionSeconds) else {
            return nil
        }
        return 1 / factor
    }
}
