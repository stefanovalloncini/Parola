import Foundation

/// Numbers and dates in the interface go through here so a file size and the date beside it
/// can never come from two different locales: `ByteCountFormatter` has no locale of its own
/// and follows the system, while `Date.FormatStyle` follows the app.
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

    static func day(_ date: Date, locale: Locale = AppFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }
}
