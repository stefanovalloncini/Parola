import Foundation

enum RecentlyDeletedCopy {
    static let urgentDaysLeft = 3

    enum ExpiryBucket: String, CaseIterable, Identifiable {
        case soon
        case later

        var id: String { rawValue }

        var caption: String {
            switch self {
            case .soon: return "Expiring soon"
            case .later: return "Expiring later"
            }
        }
    }

    static func bucket(daysLeft: Int?) -> ExpiryBucket {
        guard let daysLeft else { return .later }
        return daysLeft <= urgentDaysLeft ? .soon : .later
    }

    /// Soon first whatever the sort picked; a bucket with nothing in it gets no section.
    static func grouped<T>(_ items: [T], daysLeft: (T) -> Int?) -> [(bucket: ExpiryBucket, items: [T])] {
        ExpiryBucket.allCases.compactMap { bucket in
            let matching = items.filter { RecentlyDeletedCopy.bucket(daysLeft: daysLeft($0)) == bucket }
            return matching.isEmpty ? nil : (bucket, matching)
        }
    }

    /// What the page's own search reaches: the title always, and the transcript only where a row has decoded one.
    static func matches(query: String, title: String, preview: String?) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        if title.lowercased().contains(needle) { return true }
        return preview?.lowercased().contains(needle) ?? false
    }

    static func bulkPurgeTitle(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "Delete 1 item permanently?", bundle: bundle)
            : String(localized: "Delete \(count) items permanently?", bundle: bundle)
    }

    static func emptyTrashMessage(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "1 item will be deleted for good.", bundle: bundle)
            : String(localized: "All \(count) items will be deleted for good.", bundle: bundle)
    }

    static func restoreSelection(_ count: Int, bundle: Bundle = .main) -> String {
        String(localized: "Restore (\(count))", bundle: bundle)
    }

    static func deleteSelection(_ count: Int, bundle: Bundle = .main) -> String {
        String(localized: "Delete (\(count))…", bundle: bundle)
    }

    /// The line under the page title: how much is in the trash, and how long the trash keeps it.
    /// An empty page leaves the window to the empty state, which is already stating it.
    static func subtitle(count: Int, retentionDays: Int, bundle: Bundle = .main) -> String? {
        switch count {
        case 0: return nil
        case 1: return String(localized: "1 item · removed after \(retentionDays) days", bundle: bundle)
        default: return String(localized: "\(count) items · removed after \(retentionDays) days", bundle: bundle)
        }
    }

    static func daysLeft(deletedAt: Date?, now: Date, retentionDays: Int) -> Int? {
        guard let deletedAt else { return nil }
        let cal = Calendar.current
        let elapsed = cal.dateComponents([.day], from: cal.startOfDay(for: deletedAt), to: cal.startOfDay(for: now)).day ?? 0
        return retentionDays - elapsed
    }

    /// How much of the retention window is left, for the bar under a row. Nil when nothing dates the entry.
    static func remainingFraction(daysLeft: Int?, retentionDays: Int) -> Double? {
        guard let daysLeft, retentionDays > 0 else { return nil }
        return min(max(Double(daysLeft) / Double(retentionDays), 0), 1)
    }

    /// The row's date slot, which without the verb would read as the day the transcript was made.
    static func deletedOn(_ deletedAt: Date?, bundle: Bundle = .main) -> String? {
        guard let deletedAt else { return nil }
        return String(localized: "Deleted \(AppFormat.dayAndMonth(deletedAt))", bundle: bundle)
    }

    static func deadline(deletedAt: Date, retentionDays: Int) -> Date {
        deletedAt.addingTimeInterval(Double(retentionDays) * 86_400)
    }

    static func timeLeftLabel(deletedAt: Date?, now: Date, retentionDays: Int, bundle: Bundle = .main) -> String {
        guard let deletedAt,
              let days = daysLeft(deletedAt: deletedAt, now: now, retentionDays: retentionDays) else {
            return String(localized: "No deadline", bundle: bundle)
        }
        let remaining = deadline(deletedAt: deletedAt, retentionDays: retentionDays).timeIntervalSince(now)
        guard days >= 0, remaining > 0 else { return String(localized: "Past deadline", bundle: bundle) }
        if days > 0 {
            return days == 1
                ? String(localized: "1 day left", bundle: bundle)
                : String(localized: "\(days) days left", bundle: bundle)
        }
        let hours = Int(remaining / 3_600)
        if hours < 1 { return String(localized: "Less than an hour left", bundle: bundle) }
        return hours == 1
            ? String(localized: "1 hour left", bundle: bundle)
            : String(localized: "\(hours) hours left", bundle: bundle)
    }
}
