import Foundation
import os

/// Media that recently left a watched folder. Watchers that share one ledger recognise a file moved
/// between them, or into a subfolder rescanned later, instead of taking it for a new arrival.
public final class FolderWatcherLedger: Sendable {
    struct Departure: Sendable, Equatable {
        var size: Int64
        var modified: Date
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

    func depart(_ key: FolderWatcher.FileKey, _ departure: Departure) {
        let horizon = departure.departedAt.addingTimeInterval(-retention)
        state.withLock { state in
            state.departures = state.departures.filter { $0.value.departedAt >= horizon }
            state.departures[key] = departure
        }
    }

    /// Takes back a departure only when the file still has the size and modification date it left with.
    func claim(_ key: FolderWatcher.FileKey, size: Int64, modified: Date, now: Date) -> Departure? {
        let horizon = now.addingTimeInterval(-retention)
        return state.withLock { state in
            guard let departure = state.departures[key],
                  departure.departedAt >= horizon,
                  departure.size == size,
                  departure.modified == modified
            else { return nil }
            state.departures.removeValue(forKey: key)
            return departure
        }
    }
}
