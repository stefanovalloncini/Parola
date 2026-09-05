import Foundation
import os
import Testing
@testable import ParolaCore

extension FileDiagnosticsSink {
    /// The install-time sweep runs on a background queue, so a test that seeds fixtures after
    /// construction has to wait for it or the two sweeps race over the same files.
    func waitForInstallSweep(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if completedSweeps > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the install-time sweep never finished")
    }
}

/// Keeps only the records emitted inside `scope`. `ParolaLog`'s sink is process-wide, so a suite
/// that transcribes or runs a batch queue in parallel lands its records in whichever sink is
/// installed — and a plain capture reads them as if they were its own.
final class ScopedCapturingSink: DiagnosticsSink {
    @TaskLocal private static var capturing: UUID?

    private let token = UUID()
    private let storage = OSAllocatedUnfairLock<[LogRecord]>(initialState: [])

    var records: [LogRecord] { storage.withLock { $0 } }

    func enqueue(_ record: LogRecord) {
        guard Self.capturing == token else { return }
        storage.withLock { $0.append(record) }
    }

    func flush() async {}

    func scope<T>(_ body: () async throws -> T) async rethrows -> T {
        try await Self.$capturing.withValue(token) { try await body() }
    }
}
