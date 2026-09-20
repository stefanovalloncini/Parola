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

    /// For a row under a day header, where the date is already on screen.
    static func timeOfDay(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
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

    /// Every span on screen: the largest two units that carry meaning, abbreviated the way the locale does.
    static func duration(seconds: Double, locale: Locale = AppFormat.locale) -> String {
        let total = Int(max(0, seconds).rounded())
        guard total > 0 else {
            // A span that rounds away still ran; "0 sec" is kept for a span that truly is nothing.
            return seconds > 0
                ? "<" + span(1, allowed: [.seconds], locale: locale)
                : span(0, allowed: [.seconds], locale: locale, showsZero: true)
        }
        let allowed: Set<Duration.UnitsFormatStyle.Unit>
        if total >= 3600 {
            allowed = [.hours, .minutes]
        } else if total >= 60 {
            allowed = [.minutes, .seconds]
        } else {
            allowed = [.seconds]
        }
        return span(total, allowed: allowed, locale: locale)
    }

    private static func span(
        _ seconds: Int,
        allowed: Set<Duration.UnitsFormatStyle.Unit>,
        locale: Locale,
        showsZero: Bool = false
    ) -> String {
        Duration.seconds(seconds).formatted(
            .units(
                allowed: allowed,
                width: .abbreviated,
                zeroValueUnits: showsZero ? .show(length: 1) : .hide
            ).locale(locale)
        )
    }
}
