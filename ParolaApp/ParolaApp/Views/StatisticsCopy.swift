import Foundation
import ParolaCore

/// The sentences timing and statistics are written in, kept out of the views so both languages can be read back.
enum StatisticsCopy {
    /// The line under the page title: how much the library holds, and how much audio is behind it.
    static func subtitle(
        entries: Int,
        audioSeconds: Double,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        String(localized: "\(transcripts(entries, bundle: bundle, locale: locale)) · \(AppFormat.duration(seconds: audioSeconds, locale: locale)) transcribed", bundle: bundle)
    }

    /// Why the two timed tiles and the model table can cover less than the library does.
    static func coverage(
        _ timed: LibraryStatistics.Coverage,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        guard let since = timed.since, timed.count > 0 else {
            return String(localized: "No run has been timed yet — new transcriptions record how long they take.", bundle: bundle)
        }
        guard !timed.coversEverything else {
            return String(localized: "Timing recorded for every transcript.", bundle: bundle)
        }
        let share = "\(AppFormat.integer(timed.count, locale: locale)) / \(AppFormat.integer(timed.total, locale: locale))"
        return String(localized: "Timing recorded since \(AppFormat.day(since, locale: locale)) · \(share) transcripts", bundle: bundle)
    }

    /// The caption under the activity chart: what the shown span adds up to.
    static func activity(
        range: ActivityRange,
        entries: Int,
        audioSeconds: Double,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        guard entries > 0 else {
            switch range {
            case .days30: return String(localized: "Nothing transcribed in the last 30 days", bundle: bundle)
            case .months12: return String(localized: "Nothing transcribed in the last 12 months", bundle: bundle)
            }
        }
        return String(localized: "\(transcripts(entries, bundle: bundle, locale: locale)) · \(AppFormat.duration(seconds: audioSeconds, locale: locale)) of audio", bundle: bundle)
    }

    /// The card over a hovered bar: the day or month, then what it holds.
    static func bucket(
        label: String,
        entries: Int,
        audioSeconds: Double,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        guard entries > 0 else {
            return "\(label) · \(String(localized: "Nothing transcribed", bundle: bundle))"
        }
        return "\(label) · \(transcripts(entries, bundle: bundle, locale: locale)) · \(AppFormat.duration(seconds: audioSeconds, locale: locale))"
    }

    private static func transcripts(_ count: Int, bundle: Bundle, locale: Locale) -> String {
        count == 1
            ? String(localized: "1 transcript", bundle: bundle)
            : String(localized: "\(AppFormat.integer(count, locale: locale)) transcripts", bundle: bundle)
    }

    /// "16× real time", the only form a speed is ever shown in.
    static func speed(_ factor: Double?, bundle: Bundle = .main, locale: Locale = AppFormat.locale) -> String? {
        guard let factor else { return nil }
        return String(localized: "\(TranscriptionSpeed.label(factor, locale: locale))\u{00A0}real time", bundle: bundle)
    }

    /// The inspector's "Transcribed in" value: how long the run took, and how much faster than the audio that was.
    static func transcribedIn(
        seconds: Double,
        audioSeconds: Double?,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String {
        let took = AppFormat.duration(seconds: seconds, locale: locale)
        guard let factor = TranscriptionSpeed.factor(audioSeconds: audioSeconds, transcriptionSeconds: seconds),
              let speed = speed(factor, bundle: bundle, locale: locale)
        else {
            return took
        }
        return "\(took) · \(speed)"
    }
}

/// The two spans the activity chart draws.
enum ActivityRange: CaseIterable, Hashable {
    case days30
    case months12
}
