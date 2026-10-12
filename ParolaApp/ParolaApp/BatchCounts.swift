import Foundation
import ParolaCore

enum BatchProgress {
    /// Nothing queued or running means the batch is settled, and a frozen "3 of 3" would only add noise.
    static func counts(for jobs: [BatchJob]) -> (finished: Int, total: Int)? {
        guard jobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) else { return nil }
        return (jobs.count { $0.status == .done }, jobs.count)
    }

    /// The header's caption and whether it is a live progress count, in one pass over the queue.
    static func headerLabel(
        for jobs: [BatchJob], locale: Locale = AppFormat.locale
    ) -> (text: String, isProgress: Bool)? {
        guard !jobs.isEmpty else { return nil }
        if let counts = counts(for: jobs) {
            if counts.total == 1 {
                return (String(localized: "\(counts.finished) of 1 file", locale: locale), true)
            }
            return (
                String(localized: "\(counts.finished) of \(counts.total) files", locale: locale),
                true
            )
        }
        if jobs.count == 1 { return (String(localized: "1 file", locale: locale), false) }
        return (String(localized: "\(jobs.count) files", locale: locale), false)
    }
}

enum QueueCount {
    static func count(for jobs: [BatchJob]) -> Int {
        jobs.count { $0.status == .pending || $0.status == .transcribing }
    }

    /// A settled queue still says how much it holds; the page loses its subtitle only when it is empty.
    static func label(for jobs: [BatchJob], locale: Locale = AppFormat.locale) -> String? {
        let n = count(for: jobs)
        guard n > 0 else { return BatchProgress.headerLabel(for: jobs, locale: locale)?.text }
        return String(localized: "\(n) in queue", locale: locale)
    }
}

extension BatchJob {
    /// Same jobs, same order, same statuses: all the queue's mirrors and its saved snapshot are built from.
    static func sameQueueShape(_ lhs: [BatchJob], _ rhs: [BatchJob]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.status == $1.status && $0.url == $1.url }
    }
}

/// The queue sorted into its statuses in one pass, shared by every list that groups the jobs by status.
/// Holds only what a row draws, so a change to anything else (the saved entry, the dropped transcript) is equal.
struct BatchJobBuckets: Equatable {
    private var byStatus: [BatchJob.Status: [BatchJob]] = [:]
    private(set) var all: [BatchJob] = []

    init(_ jobs: [BatchJob] = []) {
        all.reserveCapacity(jobs.count)
        for job in jobs {
            let shown = BatchJob(
                id: job.id, url: job.url, status: job.status, error: job.error,
                segmentCount: job.segmentCount ?? job.transcript?.segments.count
            )
            all.append(shown)
            byStatus[job.status, default: []].append(shown)
        }
    }

    /// In queue order.
    func jobs(_ status: BatchJob.Status) -> [BatchJob] {
        byStatus[status] ?? []
    }

    var hasFinished: Bool {
        byStatus[.done] != nil || byStatus[.failed] != nil || byStatus[.cancelled] != nil
    }

    /// Nothing but the running job, so there is nothing a clear could take away.
    var holdsOnlyRunningJobs: Bool {
        byStatus.keys.allSatisfy { $0 == .transcribing }
    }
}
