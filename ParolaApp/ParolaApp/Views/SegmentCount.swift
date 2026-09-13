import Foundation

enum SegmentCount {
    static func label(_ count: Int, locale: Locale = AppFormat.locale) -> String {
        count == 1
            ? String(localized: "1 segment", locale: locale)
            : String(localized: "\(count) segments", locale: locale)
    }
}
