import Foundation
import ParolaCore

/// The spans Notes reads a list under: Today, Yesterday, Previous 7 Days, Previous 30 Days, then one per month.
enum LibraryDateBucket: Hashable {
    case today
    case yesterday
    case previousWeek
    case previousMonth
    case month(year: Int, month: Int)

    /// A group's id only has to be unique, so it is never a formatted date.
    var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .previousWeek: return "week"
        case .previousMonth: return "month"
        case .month(let year, let month): return "month-\(year)-\(month)"
        }
    }
}

/// The headers a list of entries reads under: Pinned, then the buckets its dates fall into.
enum LibraryDateGroups {
    /// Where each bucket starts, worked out once for a whole list instead of once for every row in it.
    struct Edges {
        let now: Date
        let calendar: Calendar
        private let today: Date
        private let yesterday: Date
        private let previousWeek: Date
        private let previousMonth: Date

        init(now: Date, calendar: Calendar) {
            let today = calendar.startOfDay(for: now)
            self.now = now
            self.calendar = calendar
            self.today = today
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            previousWeek = calendar.date(byAdding: .day, value: -7, to: today) ?? yesterday
            previousMonth = calendar.date(byAdding: .day, value: -30, to: today) ?? previousWeek
        }

        func bucket(for date: Date) -> LibraryDateBucket {
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= previousWeek { return .previousWeek }
            if date >= previousMonth { return .previousMonth }
            let parts = calendar.dateComponents([.year, .month], from: date)
            return .month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar) -> LibraryDateBucket {
        Edges(now: now, calendar: calendar).bucket(for: date)
    }

    static func title(for bucket: LibraryDateBucket, now: Date, calendar: Calendar, locale: Locale) -> String {
        switch bucket {
        case .today: return String(localized: "Today", locale: locale)
        case .yesterday: return String(localized: "Yesterday", locale: locale)
        case .previousWeek: return String(localized: "Previous 7 Days", locale: locale)
        case .previousMonth: return String(localized: "Previous 30 Days", locale: locale)
        case .month(let year, let month):
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let name: Date.FormatStyle = calendar.component(.year, from: now) == year
                ? .dateTime.month(.wide)
                : .dateTime.month(.wide).year()
            return first.formatted(LibraryRowFormat.style(name, calendar: calendar, locale: locale))
        }
    }

    struct Group: Identifiable {
        let id: String
        /// nil for the single group a list falls back to when it isn't read by date.
        let title: String?
        let rows: [LibraryRowDisplay]
    }

    /// One list's headers, settled once: the bucket over each row, and so what the row still has to say of its time.
    struct Headers {
        let sortOrder: LibrarySortOrder
        let groupsByDate: Bool
        let edges: Edges
        let locale: Locale

        init(
            sortOrder: LibrarySortOrder,
            groupsByDate: Bool,
            now: Date = Date(),
            calendar: Calendar = .autoupdatingCurrent,
            locale: Locale = AppFormat.locale
        ) {
            self.sortOrder = sortOrder
            self.groupsByDate = groupsByDate
            edges = Edges(now: now, calendar: calendar)
            self.locale = locale
        }

        func when(for entry: LibraryEntry) -> String {
            LibraryRowFormat.when(entry.createdAt, under: bucket(over: entry), edges: edges, locale: locale)
        }

        func groups(for rows: [LibraryRowDisplay]) -> [Group] {
            guard groupsByDate else { return LibraryDateGroups.ungrouped(rows) }
            return LibraryDateGroups.groups(
                for: rows, sortOrder: sortOrder, now: edges.now, calendar: edges.calendar, locale: locale
            )
        }

        /// nil where no date header sits over the row: a pinned row, which leads under Pinned, or a list not read by date.
        private func bucket(over entry: LibraryEntry) -> LibraryDateBucket? {
            guard groupsByDate, sortOrder.isChronological, !entry.pinned else { return nil }
            return edges.bucket(for: entry.createdAt)
        }
    }

    /// The one group a search or an undated list runs under: no header, so each row names its own day.
    static func ungrouped(_ rows: [LibraryRowDisplay], id: String = "all") -> [Group] {
        rows.isEmpty ? [] : [Group(id: id, title: nil, rows: rows)]
    }

    /// A header wherever the bucket changes, so newest-first and oldest-first both read in order.
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
            groups.append(Group(id: "pinned", title: String(localized: "Pinned", locale: locale), rows: pinned))
        }
        let edges = Edges(now: now, calendar: calendar)
        var runs: [(bucket: LibraryDateBucket, rows: [LibraryRowDisplay])] = []
        for row in rows where !(pinsFirst && row.pinned) {
            let bucket = edges.bucket(for: row.entry.createdAt)
            if runs.last?.bucket == bucket {
                runs[runs.count - 1].rows.append(row)
            } else {
                runs.append((bucket, [row]))
            }
        }
        for run in runs {
            groups.append(Group(
                id: run.bucket.id,
                title: title(for: run.bucket, now: now, calendar: calendar, locale: locale),
                rows: run.rows
            ))
        }
        return groups
    }
}

extension LibrarySortOrder {
    /// Date headers only make sense while the rows run in the order their dates do.
    var isChronological: Bool {
        self == .newest || self == .oldest
    }
}
