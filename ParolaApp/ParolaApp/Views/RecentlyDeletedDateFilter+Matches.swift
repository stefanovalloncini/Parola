import Foundation

extension RecentlyDeletedDateFilter {
    func matches(_ deletedAt: Date?, now: Date) -> Bool {
        guard self != .all else { return true }
        guard let deletedAt else { return self == .older }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: deletedAt), to: cal.startOfDay(for: now)).day ?? 0
        switch self {
        case .all: return true
        case .today: return cal.isDateInToday(deletedAt)
        case .week: return days < 7
        case .month: return days < 30
        case .older: return days >= 30
        }
    }
}
