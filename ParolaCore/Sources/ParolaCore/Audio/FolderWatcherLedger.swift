import Foundation
import os

/// Media that recently left a watched folder. Watchers that share one ledger recognise a file moved
/// between them, or into a subfolder rescanned later, instead of taking it for a new arrival.
public final class FolderWatcherLedger: Sendable {
    struct Departure: Sendable, Equatable {
        var size: Int64
        var modified: Date
        var created: Date?
        var status: FolderWatcher.FileStatus
        var departedAt: Date
    }

    private struct State {
        var departures: [FolderWatcher.FileKey: Departure] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let retention: TimeInterval

    public init(retention: Duration = .seconds(600)) {
        let parts = retention.components
        self.retention = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// One prune per batch, so a whole subtree leaving costs one pass over what the ledger holds.
    func depart(_ departures: [FolderWatcher.FileKey: Departure], now: Date) {
        guard !departures.isEmpty else { return }
        let horizon = now.addingTimeInterval(-retention)
        state.withLock { state in
            state.departures = state.departures.filter { $0.value.departedAt >= horizon }
            state.departures.merge(departures) { _, new in new }
        }
    }

    var count: Int {
        state.withLock { $0.departures.count }
    }

    static func isLater(_ listed: Date?, than recorded: Date?) -> Bool {
        guard let listed, let recorded else { return false }
        return listed > recorded
    }

    /// Takes back a departure only when the file still has the size, dates and birth time it left with.
    func claim(_ key: FolderWatcher.FileKey, size: Int64, modified: Date, created: Date?, now: Date) -> Departure? {
        let horizon = now.addingTimeInterval(-retention)
        return state.withLock { state in
            guard let departure = state.departures[key],
                  departure.departedAt >= horizon,
                  departure.size == size,
                  departure.modified == modified,
                  !Self.isLater(created, than: departure.created)
            else { return nil }
            state.departures.removeValue(forKey: key)
            return departure
        }
    }
}

/// Caps the descriptors all watchers hold for subfolder sources, keeping a reserve; folders past it are polled.
final class FolderSourceBudget: Sendable {
    static let shared = FolderSourceBudget(limit: FolderSourceBudget.processLimit())

    let limit: Int
    private let used = OSAllocatedUnfairLock(initialState: 0)

    init(limit: Int) {
        self.limit = limit
    }

    var inUse: Int {
        used.withLock { $0 }
    }

    func acquire() -> Bool {
        used.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() {
        used.withLock { $0 = max(0, $0 - 1) }
    }

    static func processLimit() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let soft = Int(clamping: limit.rlim_cur)
        return soft - min(512, soft / 2)
    }
}
