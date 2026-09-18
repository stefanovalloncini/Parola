import Foundation

/// How much faster than real time a transcription ran: audio seconds over the wall-clock seconds
/// the engine took. Frontends show the multiple ("16×"), never the reciprocal.
public enum TranscriptionSpeed {
    /// What the CLI and the MCP server format in: their output is read by scripts, so the decimal
    /// separator has to be the same on every machine. The app passes `AppFormat.locale` instead.
    public static let toolLocale = Locale(identifier: "en_US_POSIX")

    public static func factor(audioSeconds: Double?, transcriptionSeconds: Double?) -> Double? {
        guard let audioSeconds, let transcriptionSeconds,
              audioSeconds.isFinite, transcriptionSeconds.isFinite,
              audioSeconds > 0, transcriptionSeconds > 0
        else { return nil }
        return audioSeconds / transcriptionSeconds
    }

    /// A tenth below ten, whole numbers above it: past 10× the first decimal is noise.
    public static func label(_ factor: Double, locale: Locale = TranscriptionSpeed.toolLocale) -> String {
        // Decided on the rounded value, or 9.96 takes the decimal branch and renders "10.0×".
        let digits = ((factor * 10).rounded() / 10) < 10 ? 1 : 0
        let number = factor.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return "\(number)×"
    }

    /// A span in the form every tool prints: seconds alone under a minute, then minutes, then hours.
    public static func duration(seconds: Double, locale: Locale = TranscriptionSpeed.toolLocale) -> String {
        let total = Int(max(0, seconds).rounded())
        let whole = { (value: Int) in value.formatted(.number.locale(locale)) }
        let padded = { (value: Int) in value.formatted(.number.precision(.integerLength(2)).locale(locale)) }
        // A span that rounds away to nothing still took time; a bare "0 s" reads as "not measured".
        if total == 0, seconds > 0 { return "<1 s" }
        guard total >= 60 else { return "\(whole(total)) s" }
        guard total >= 3600 else { return "\(whole(total / 60)) min \(padded(total % 60)) s" }
        return "\(whole(total / 3600)) h \(padded((total % 3600) / 60)) min \(padded(total % 60)) s"
    }

    /// What a finished run reports outside the app: "Transcribed in 37 s (16× real time)".
    public static func runSummary(
        seconds: Double,
        audioSeconds: Double?,
        showsRealTimeFactor: Bool = false,
        locale: Locale = TranscriptionSpeed.toolLocale
    ) -> String {
        let took = duration(seconds: seconds, locale: locale)
        guard let speed = factor(audioSeconds: audioSeconds, transcriptionSeconds: seconds) else {
            return "Transcribed in \(took)"
        }
        var detail = "\(label(speed, locale: locale)) real time"
        if showsRealTimeFactor, let rtf = realTimeFactor(audioSeconds: audioSeconds, transcriptionSeconds: seconds) {
            detail += ", RTF \(String(format: "%.2f", rtf))"
        }
        return "Transcribed in \(took) (\(detail))"
    }

    /// The ratio the other way round, for tooling that asks for it by name. Never shown on its own in the UI.
    public static func realTimeFactor(audioSeconds: Double?, transcriptionSeconds: Double?) -> Double? {
        guard let factor = factor(audioSeconds: audioSeconds, transcriptionSeconds: transcriptionSeconds) else {
            return nil
        }
        return 1 / factor
    }
}
