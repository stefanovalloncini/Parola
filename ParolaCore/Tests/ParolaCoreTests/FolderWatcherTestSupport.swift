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

actor ManualScheduler: FolderWatcherScheduler {
    private struct Parked {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var parked: [Parked] = []
    private var cancelledBeforeParking: Set<UUID> = []
    private var done: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    var parkedCount: Int { parked.count }

    func runTick(after interval: Duration, _ body: @Sendable @escaping () async -> Void) async throws {
        guard await park() else { throw CancellationError() }
        await body()
        signalDone()
    }

    /// Runs `ticks` settle checks. A settled file arrives on the second check after the scan that found it.
    func advance(ticks: Int) async throws {
        for _ in 0..<ticks {
            try await advanceAndWait()
        }
    }

    func advanceAndWait() async throws {
        if parked.isEmpty {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                arrivalWaiters.append(cont)
            }
        }
        let go = parked.removeFirst()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            done.append(cont)
            go.continuation.resume(returning: true)
        }
    }

    /// A tick cancelled by `stop()` resumes with `false` instead of leaking its continuation.
    private func park() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if cancelledBeforeParking.remove(id) != nil {
                    cont.resume(returning: false)
                    return
                }
                parked.append(Parked(id: id, continuation: cont))
                if let waiter = arrivalWaiters.first {
                    arrivalWaiters.removeFirst()
                    waiter.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelParked(id) }
        }
    }

    private func cancelParked(_ id: UUID) {
        if let index = parked.firstIndex(where: { $0.id == id }) {
            parked.remove(at: index).continuation.resume(returning: false)
        } else {
            cancelledBeforeParking.insert(id)
        }
    }

    private func signalDone() {
        guard !done.isEmpty else { return }
        done.removeFirst().resume()
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
