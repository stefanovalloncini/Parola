import Foundation
import ParolaCore

/// The sentences timing and statistics are written in, kept out of the views so both languages can be read back.
enum StatisticsCopy {
    /// "16× real time", the only form a speed is ever shown in.
    static func speed(_ factor: Double?, bundle: Bundle = .main, locale: Locale = AppFormat.locale) -> String? {
        guard let factor else { return nil }
        return String(localized: "\(TranscriptionSpeed.label(factor, locale: locale)) real time", bundle: bundle)
    }

    /// The inspector's "Transcribed in" value: how long the run took, and how much faster than the audio that was.
    static func transcribedIn(
        seconds: Double,
        audioSeconds: Double?,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        let took = AppFormat.runDuration(seconds: seconds, locale: locale)
        guard let factor = TranscriptionSpeed.factor(audioSeconds: audioSeconds, transcriptionSeconds: seconds),
              let speed = speed(factor, bundle: bundle, locale: locale)
        else {
            return took
        }
        return "\(took) · \(speed)"
    }
}
