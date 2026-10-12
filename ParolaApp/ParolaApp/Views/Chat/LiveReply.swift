import Foundation
import Observation

/// The reply still streaming in. Only the last bubble reads `shown`, which trails `said` by at most one flush interval.
@MainActor
@Observable
final class LiveReply {
    static let flushInterval: Duration = .milliseconds(80)

    private(set) var replyID: UUID?
    private(set) var shown = ""
    @ObservationIgnored private(set) var said = ""
    @ObservationIgnored private var lastFlush: ContinuousClock.Instant?
    @ObservationIgnored private var trailing: Task<Void, Never>?

    var hasPendingFlush: Bool { trailing != nil }

    func append(_ delta: String, replyID id: UUID, at now: ContinuousClock.Instant = .now) {
        if replyID != id {
            reset()
            replyID = id
        }
        said += delta
        guard let lastFlush, now - lastFlush < Self.flushInterval else {
            flush(at: now)
            return
        }
        guard trailing == nil else { return }
        let wait = Self.flushInterval - (now - lastFlush)
        trailing = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flush(at: .now)
        }
    }

    func end() {
        reset()
        replyID = nil
    }

    func end(ifHolding id: UUID) {
        if replyID == id { end() }
    }

    private func reset() {
        trailing?.cancel()
        trailing = nil
        lastFlush = nil
        said = ""
        shown = ""
    }

    private func flush(at now: ContinuousClock.Instant) {
        trailing?.cancel()
        trailing = nil
        lastFlush = now
        if shown != said { shown = said }
    }
}
