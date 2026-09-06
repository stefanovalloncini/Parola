import Foundation
import ParolaCore

enum BatchProgress {
    /// Nothing queued or running means the batch is settled, and a frozen "3 of 3" would only add noise.
    static func counts(for jobs: [BatchJob]) -> (finished: Int, total: Int)? {
        guard jobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) else { return nil }
        return (jobs.count { $0.status == .done }, jobs.count)
    }

    static func filesLabel(for jobs: [BatchJob], locale: Locale = AppFormat.locale) -> String? {
        guard !jobs.isEmpty else { return nil }
        if let counts = counts(for: jobs) {
            if counts.total == 1 {
                return String(localized: "\(counts.finished) of 1 file", locale: locale)
            }
            return String(localized: "\(counts.finished) of \(counts.total) files", locale: locale)
        }
        if jobs.count == 1 { return String(localized: "1 file", locale: locale) }
        return String(localized: "\(jobs.count) files", locale: locale)
    }
}

enum QueueCount {
    static func count(for jobs: [BatchJob]) -> Int {
        jobs.count { $0.status == .pending || $0.status == .transcribing }
    }

    static func label(for jobs: [BatchJob], locale: Locale = AppFormat.locale) -> String? {
        let n = count(for: jobs)
        guard n > 0 else { return nil }
        return String(localized: "\(n) in queue", locale: locale)
    }
}
