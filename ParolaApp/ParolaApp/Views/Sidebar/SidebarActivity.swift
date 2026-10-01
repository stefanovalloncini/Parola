import Foundation
import ParolaCore

/// The Activity row: the work still to run, or once none is left, the jobs that failed in the last day.
enum SidebarActivity: Equatable {
    case inProgress(count: Int)
    case failed(count: Int)

    static let failureWindow: TimeInterval = 24 * 3600

    /// A failed job with no time on record counts as failing now.
    static func current(jobs: [BatchJob], failedAt: [BatchJob.ID: Date], now: Date) -> SidebarActivity? {
        let remaining = QueueCount.count(for: jobs)
        if remaining > 0 { return .inProgress(count: remaining) }
        let recent = jobs.count { job in
            job.status == .failed && now.timeIntervalSince(failedAt[job.id] ?? now) < failureWindow
        }
        return recent > 0 ? .failed(count: recent) : nil
    }

    /// When the next failure still counted leaves the window.
    static func nextExpiry(failedAt: [BatchJob.ID: Date], now: Date) -> Date? {
        failedAt.values.lazy.map { $0.addingTimeInterval(failureWindow) }.filter { $0 > now }.min()
    }

    var count: Int {
        switch self {
        case .inProgress(let count), .failed(let count): count
        }
    }

    /// The source key, so the casing and the Italian can be read back.
    var title: String {
        switch self {
        case .inProgress: "In Progress"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .inProgress: "hourglass"
        case .failed: "exclamationmark.triangle"
        }
    }
}
