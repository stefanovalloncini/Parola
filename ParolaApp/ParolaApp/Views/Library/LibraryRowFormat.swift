import Foundation

/// The words a library row and its page header use for when a take was made and how long it runs.
enum LibraryRowFormat {
    /// A length in words, never a clock; nothing at all for a length the manifest doesn't really have.
    static func duration(_ seconds: Double?, bundle: Bundle = .main) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return AppFormat.duration(seconds: seconds, bundle: bundle)
    }

    /// The same length as VoiceOver says it, to the unit the row shows: "1 hour, 12 minutes", "1 ora e 12 minuti".
    static func spokenDuration(_ seconds: Double?, bundle: Bundle = .main, locale: Locale = AppFormat.locale) -> String? {
        if let seconds, seconds > 0, seconds < 1 { return String(localized: "less than a second", bundle: bundle) }
        guard let total = wholeSeconds(seconds) else { return nil }
        let shown: Duration = .seconds(total < 60 ? total : total / 60 * 60)
        let units: Set<Duration.UnitsFormatStyle.Unit> = total < 60 ? [.seconds] : [.hours, .minutes]
        return shown.formatted(.units(allowed: units, width: .wide).locale(locale))
    }

    /// `Int(exactly:)` rather than `Int(_:)`: a damaged manifest's infinity would trap the conversion.
    private static func wholeSeconds(_ seconds: Double?) -> Int? {
        guard let seconds, seconds > 0, let whole = Int(exactly: seconds.rounded(.towardZero)) else { return nil }
        return max(1, whole)
    }

    /// One element's worth of words for a row: its title, what marks it, what it says, then when and how long.
    static func spokenLabel(for row: LibraryRowDisplay, detail: [String], bundle: Bundle = .main) -> String {
        var parts = [row.title]
        if row.pinned { parts.append(String(localized: "Pinned", bundle: bundle)) }
        parts += row.labels
        if let language = row.language { parts.append(language) }
        parts += detail.filter { !$0.isEmpty }
        parts.append(row.when)
        if let duration = row.spokenDuration { parts.append(duration) }
        return parts.joined(separator: ", ")
    }

    /// Under a date header a row says only what the header leaves out; with no header over it, it names its day too.
    static func when(
        _ date: Date,
        under bucket: LibraryDateBucket?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppFormat.locale
    ) -> String {
        when(date, under: bucket, edges: LibraryDateGroups.Edges(now: now, calendar: calendar), locale: locale)
    }

    static func when(_ date: Date, under bucket: LibraryDateBucket?, edges: LibraryDateGroups.Edges, locale: Locale) -> String {
        let calendar = edges.calendar
        let resolved = bucket ?? edges.bucket(for: date)
        switch resolved {
        case .today, .yesterday:
            let time = shortTime(date, calendar: calendar, locale: locale)
            guard bucket == nil else { return time }
            return resolved == .today
                ? String(localized: "Today \(time)", locale: locale)
                : String(localized: "Yesterday \(time)", locale: locale)
        case .previousWeek:
            let weekday = date.formatted(style(.dateTime.weekday(.abbreviated), calendar: calendar, locale: locale))
            return "\(weekday) \(shortTime(date, calendar: calendar, locale: locale))"
        case .previousMonth, .month:
            let thisYear = calendar.component(.year, from: date) == calendar.component(.year, from: edges.now)
            let day: Date.FormatStyle = thisYear
                ? .dateTime.day().month(.abbreviated)
                : .dateTime.day().month(.abbreviated).year()
            return date.formatted(style(day, calendar: calendar, locale: locale))
        }
    }

    /// The locale's own short time, which never pads the hour the way a 24-hour region's hour field does.
    private static func shortTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(style(Date.FormatStyle(date: .omitted, time: .shortened), calendar: calendar, locale: locale))
    }

    /// Italian writes month and weekday names in lower case unless they stand alone, as a header or a row's time does.
    static func style(_ base: Date.FormatStyle, calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        var style = base.locale(locale)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.capitalizationContext = .standalone
        return style
    }

    static func usualLanguage(codes: [String]) -> String? {
        var counts: [String: Int] = [:]
        for code in codes { counts[code, default: 0] += 1 }
        return counts.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
    }

    static func subtitle(count: Int, totalSeconds: Double, bundle: Bundle = .main) -> String {
        let transcripts = String(localized: "\(count) transcripts", bundle: bundle)
        guard let length = duration(totalSeconds, bundle: bundle) else { return transcripts }
        return "\(transcripts) · \(length)"
    }

    static func spokenSubtitle(count: Int, totalSeconds: Double, bundle: Bundle = .main, locale: Locale = AppFormat.locale) -> String {
        let transcripts = String(localized: "\(count) transcripts", bundle: bundle)
        guard let length = spokenDuration(totalSeconds, bundle: bundle, locale: locale) else { return transcripts }
        return "\(transcripts), \(length)"
    }
}
