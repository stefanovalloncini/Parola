import Foundation
import os

/// A destination for diagnostics records. `enqueue` is synchronous and must not
/// block: implementations buffer and drain on their own schedule.
public protocol DiagnosticsSink: Sendable {
    func enqueue(_ record: LogRecord)
    func flush() async
}

public final class CapturingDiagnosticsSink: DiagnosticsSink {
    private let storage = OSAllocatedUnfairLock<[LogRecord]>(initialState: [])

    public init() {}

    public var records: [LogRecord] { storage.withLock { $0 } }

    public func clear() { storage.withLock { $0 = [] } }

    public func enqueue(_ record: LogRecord) {
        storage.withLock { $0.append(record) }
    }

    public func flush() async {}
}
