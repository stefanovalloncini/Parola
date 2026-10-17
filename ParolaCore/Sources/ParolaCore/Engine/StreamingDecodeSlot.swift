import Foundation

/// Hands a dictation controller its own decode slot, so re-arming it never inherits a decode that hung.
public final class DecodeSerializer: Sendable {
    let slot = StreamingDecodeSlot()

    public init() {}
}

/// Lets one streaming decode run at a time, so a dictation take finishing its tail never overlaps the next take's live decodes.
actor StreamingDecodeSlot {
    private var holder: UInt64?
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID: UInt64 = 0

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let id = try await acquire()
        return try await withTaskCancellationHandler {
            defer { release(id) }
            return try await work()
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    private func acquire() async throws -> UInt64 {
        try Task.checkCancellation()
        nextID &+= 1
        let id = nextID
        guard holder != nil else {
            holder = id
            return id
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return id
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UInt64) {
        guard holder == id else { return }
        guard !waiters.isEmpty else {
            holder = nil
            return
        }
        let next = waiters.removeFirst()
        holder = next.id
        next.continuation.resume()
    }
}
