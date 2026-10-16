import Foundation

/// Lets one streaming decode run at a time, so a take finishing its tail never overlaps the next take's live decodes.
actor StreamingDecodeSlot {
    static let shared = StreamingDecodeSlot()

    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID: UInt64 = 0

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        nextID &+= 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}
