import Foundation

enum SegmentCount {
    static func label(_ count: Int, locale: Locale = AppFormat.locale) -> String {
        count == 1
            ? String(localized: "1 segment", locale: locale)
            : String(localized: "\(count) segments", locale: locale)
    }

    /// How often a person has been assigned to a speaker, for the People directory rows.
    static func assignments(_ count: Int, locale: Locale = AppFormat.locale) -> String {
        count == 1
            ? String(localized: "1 assignment", locale: locale)
            : String(localized: "\(count) assignments", locale: locale)
    }
}
