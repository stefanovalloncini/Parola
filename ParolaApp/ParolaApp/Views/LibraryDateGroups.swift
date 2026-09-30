import Foundation
import ParolaCore

/// The day headers a list of entries reads under: "Today", "Yesterday", then the date itself.
enum LibraryDateGroups {
    struct Group: Identifiable {
        let id: String
        /// nil for the single group a list falls back to when its order has nothing to do with dates.
        let title: String?
        /// A day group carries the date in its header, so its rows show only the time.
        let showsTime: Bool
        let rows: [LibraryRowDisplay]
    }

    /// The one group a search or a title sort runs under: no header, rows dated in full.
    static func ungrouped(_ rows: [LibraryRowDisplay], id: String = "all") -> [Group] {
        rows.isEmpty ? [] : [Group(id: id, title: nil, showsTime: false, rows: rows)]
    }

    static func groups(
        for rows: [LibraryRowDisplay],
        sortOrder: LibrarySortOrder = .newest,
        pinsFirst: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppFormat.locale
    ) -> [Group] {
        guard sortOrder.isChronological else { return ungrouped(rows) }
        guard !rows.isEmpty else { return [] }
        var groups: [Group] = []
        let pinned = pinsFirst ? rows.filter(\.pinned) : []
        if !pinned.isEmpty {
            groups.append(Group(
                id: "pinned",
                title: String(localized: "Pinned", locale: locale),
                showsTime: false,
                rows: pinned
            ))
        }
        var order: [Date] = []
        var byDay: [Date: [LibraryRowDisplay]] = [:]
        for row in rows where !(pinsFirst && row.pinned) {
            let day = calendar.startOfDay(for: row.entry.createdAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row)
        }
        for day in order {
            groups.append(Group(
                id: id(for: day),
                title: title(for: day, now: now, calendar: calendar, locale: locale),
                showsTime: true,
                rows: byDay[day] ?? []
            ))
        }
        return groups
    }

    /// Never shown: a group id only has to be unique, and formatting a date for one costs 199 µs.
    private static func id(for day: Date) -> String {
        "day-\(Int(day.timeIntervalSinceReferenceDate))"
    }

    static func title(
        for day: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppFormat.locale
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today", locale: locale) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", locale: locale)
        }
        return AppFormat.day(day, locale: locale)
    }
}

extension LibrarySortOrder {
    /// Day headers only make sense while the rows run in the order the days do.
    var isChronological: Bool {
        self == .newest || self == .oldest
    }
}
