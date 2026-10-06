import Foundation

/// One locale for every number and date on screen; `ByteCountFormatter` has none of its own.
enum AppFormat {
    static let locale: Locale = .autoupdatingCurrent

    static func byteSize(_ bytes: Int64, locale: Locale = AppFormat.locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    static func byteSize(_ bytes: Int, locale: Locale = AppFormat.locale) -> String {
        byteSize(Int64(bytes), locale: locale)
    }

    static func dateAndTime(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func longDateAndTime(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    }

    static func dayAndMonth(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    static func month(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).locale(locale))
    }

    static func monthAndYear(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).year().locale(locale))
    }

    static func day(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// A count on screen: grouped the way the locale groups, not by raw interpolation.
    static func integer(_ value: Int, locale: Locale = AppFormat.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    static func percent(_ fraction: Double, fractionDigits: Int = 0, locale: Locale = AppFormat.locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// A running clock: m:ss under an hour, h:mm:ss from the hour on, counting whole seconds.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// A running clock read aloud: whole words, with seconds kept past the hour ("1 hour, 2 minutes, 5 seconds").
    static func spokenDuration(seconds: Int, locale: Locale = AppFormat.locale) -> String {
        Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale)
        )
    }

    /// Every length on screen, the library rows' form: "8 s", "38 min", "1 h 12 min"; "<1 s" for a span too short to count.
    static func duration(seconds: Double, bundle: Bundle = .main) -> String {
        guard seconds.isFinite, seconds > 0 else { return String(localized: "\(0) s", bundle: bundle) }
        let total = Int(min(seconds, Double(Int32.max)))
        // A span too short to count still ran; "0 s" is kept for one that truly is nothing.
        guard total > 0 else { return "<" + String(localized: "\(1) s", bundle: bundle) }
        if total < 60 { return String(localized: "\(total) s", bundle: bundle) }
        let hours = total / 3600
        let minutes = total % 3600 / 60
        guard hours > 0 else { return String(localized: "\(minutes) min", bundle: bundle) }
        return minutes == 0
            ? String(localized: "\(hours) h", bundle: bundle)
            : String(localized: "\(hours) h \(minutes) min", bundle: bundle)
    }
}
