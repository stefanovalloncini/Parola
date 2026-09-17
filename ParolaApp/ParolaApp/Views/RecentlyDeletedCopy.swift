import Foundation

enum RecentlyDeletedCopy {
    enum Tier {
        case calm
        case soon
        case critical
        case overdue
        case undated
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

    static func selectionCount(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "1 selected", bundle: bundle)
            : String(localized: "\(count) selected", bundle: bundle)
    }

    static func subtitleCount(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "1 item", bundle: bundle)
            : String(localized: "\(count) items", bundle: bundle)
    }

    /// The line under the page title: how much is in the trash, and how long the trash keeps it.
    static func subtitle(count: Int, retentionDays: Int, bundle: Bundle = .main) -> String {
        guard count > 0 else {
            return String(localized: "Nothing deleted · items are kept \(retentionDays) days", bundle: bundle)
        }
        let items = subtitleCount(count, bundle: bundle)
        return String(localized: "\(items) · removed after \(retentionDays) days", bundle: bundle)
    }

    static func daysLeft(deletedAt: Date?, now: Date, retentionDays: Int) -> Int? {
        guard let deletedAt else { return nil }
        let cal = Calendar.current
        let elapsed = cal.dateComponents([.day], from: cal.startOfDay(for: deletedAt), to: cal.startOfDay(for: now)).day ?? 0
        return retentionDays - elapsed
    }

    static func tier(daysLeft: Int?) -> Tier {
        guard let daysLeft else { return .undated }
        if daysLeft < 0 { return .overdue }
        if daysLeft <= 2 { return .critical }
        if daysLeft <= 7 { return .soon }
        return .calm
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
