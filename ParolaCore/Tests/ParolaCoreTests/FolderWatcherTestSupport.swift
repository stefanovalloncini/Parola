import Foundation
import os
@testable import ParolaCore

final class CollectedURLs: Sendable {
    private let storage = OSAllocatedUnfairLock<[URL]>(initialState: [])
    func append(_ url: URL) {
        storage.withLock { $0.append(url) }
    }
    func snapshot() -> [URL] {
        storage.withLock { $0 }
    }
}

struct FixedClock: FolderWatcherClock {
    let start: Date
    func now() -> Date { start }
}

/// Ticks run only when a test advances them. Cancelling a tick takes it off the list at once, under the
/// lock, so an advance can never resume a tick the watcher already replaced.
final class ManualScheduler: FolderWatcherScheduler, Sendable {
    struct NoTickScheduled: Error {}

    private struct Parked {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var parked: [Parked] = []
        var cancelledBeforeParking: Set<UUID> = []
        var done: [CheckedContinuation<Void, Never>] = []
        var waiters: [Waiter] = []
        var intervals: [Duration] = []
    }

    private enum Parking {
        case parked(wake: CheckedContinuation<Bool, Never>?)
        case cancelled
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var parkedCount: Int { state.withLock { $0.parked.count } }
    /// The interval of every tick that was armed, in order; one cancelled before it parked is left out.
    var intervals: [Duration] { state.withLock { $0.intervals } }

    func runTick(after interval: Duration, _ body: @Sendable @escaping () async -> Void) async throws {
        let id = UUID()
        let go = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let parking = state.withLock { state -> Parking in
                    if state.cancelledBeforeParking.remove(id) != nil { return .cancelled }
                    state.intervals.append(interval)
                    state.parked.append(Parked(id: id, continuation: continuation))
                    return .parked(wake: state.waiters.isEmpty ? nil : state.waiters.removeFirst().continuation)
                }
                switch parking {
                case .cancelled: continuation.resume(returning: false)
                case .parked(let wake): wake?.resume(returning: true)
                }
            }
        } onCancel: {
            let parked = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                if let index = state.parked.firstIndex(where: { $0.id == id }) {
                    return state.parked.remove(at: index).continuation
                }
                state.cancelledBeforeParking.insert(id)
                return nil
            }
            parked?.resume(returning: false)
        }
        guard go else { throw CancellationError() }
        await body()
        let done = state.withLock { $0.done.isEmpty ? nil : $0.done.removeFirst() }
        done?.resume()
    }

    /// Runs `ticks` settle checks. A settled file arrives on the third check after the scan that found it.
    func advance(ticks: Int) async throws {
        for _ in 0..<ticks {
            try await advanceAndWait()
        }
    }

    /// Runs the armed tick to the end. Fails instead of hanging when the watcher never arms one.
    func advanceAndWait() async throws {
        while true {
            let next = state.withLock { $0.parked.isEmpty ? nil : $0.parked.removeFirst() }
            if let next {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.done.append(continuation) }
                    next.continuation.resume(returning: true)
                }
                return
            }
            try await waitForArmedTick()
        }
    }

    /// Returns once a tick is armed, so `intervals` is read after the watcher scheduled its next check.
    func waitForArmedTick() async throws {
        let id = UUID()
        let armed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let ready = state.withLock { state -> Bool in
                if !state.parked.isEmpty { return true }
                state.waiters.append(Waiter(id: id, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                let expired = self.state.withLock { state -> CheckedContinuation<Bool, Never>? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiters.remove(at: index).continuation
                }
                expired?.resume(returning: false)
            }
        }
        guard armed else { throw NoTickScheduled() }
    }
}

enum WatchedFolderFixture {
    static func makeTempDir(_ label: String = "folderwatch") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes under a hidden name, dates it and renames it into place, so no scan sees it half made.
    static func writeSettled(_ url: URL, clock: FixedClock, bytes: Int = 1024) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        try Data(count: bytes).write(to: staging)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-10)],
            ofItemAtPath: staging.path
        )
        try FileManager.default.moveItem(at: staging, to: url)
    }

    static func names(_ paths: Set<String>) -> Set<String> {
        Set(paths.map { ($0 as NSString).lastPathComponent })
    }
}
