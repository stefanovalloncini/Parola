import Foundation
import os

public final class FileDiagnosticsSink: DiagnosticsSink {
    private struct State {
        var buffer: [LogRecord] = []
        var handle: FileHandle?
        var bytesWritten: Int = 0
        var rotation: Int = 0
        var disabled: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let directory: URL
    private let minimumLevel: LogLevel
    private let maxFileBytes: Int
    private let retentionDays: Int
    private let totalBudgetBytes: Int
    private let baseName: String

    public init(
        directory: URL,
        minimumLevel: LogLevel = .info,
        maxFileBytes: Int = 5_000_000,
        retentionDays: Int = 7,
        totalBudgetBytes: Int = 10_000_000
    ) {
        self.directory = directory
        self.minimumLevel = minimumLevel
        self.maxFileBytes = maxFileBytes
        self.retentionDays = retentionDays
        self.totalBudgetBytes = totalBudgetBytes
        let pid = ProcessInfo.processInfo.processIdentifier
        let epoch = Int(Date().timeIntervalSince1970)
        self.baseName = "parola-\(pid)-\(epoch)"
    }

    public var isDisabled: Bool { state.withLock { $0.disabled } }

    public var currentFileURL: URL {
        let rotation = state.withLock { $0.rotation }
        let name = rotation == 0 ? "\(baseName).jsonl" : "\(baseName)-\(rotation).jsonl"
        return directory.appendingPathComponent(name)
    }

    public func enqueue(_ record: LogRecord) {
        guard record.level >= minimumLevel else { return }
        let shouldDrainNow: Bool = state.withLock { current in
            guard !current.disabled else { return false }
            current.buffer.append(record)
            return record.level >= .error || current.buffer.count >= 64
        }
        if shouldDrainNow { drain() }
    }

    public func flush() async {
        drain()
    }

    private func drain() {
        let pending: [LogRecord] = state.withLock { current in
            guard !current.disabled, !current.buffer.isEmpty else { return [] }
            let records = current.buffer
            current.buffer = []
            return records
        }
        guard !pending.isEmpty else { return }

        var payload = Data()
        for record in pending {
            guard let line = Self.encode(record) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        write(payload)
    }

    private static func encode(_ record: LogRecord) -> Data? {
        var object: [String: Any] = [
            "ts": LogTimestamp.string(from: record.timestamp),
            "level": record.level.name,
            "subsystem": record.subsystem,
            "category": record.category.rawValue,
            "message": record.message.rendered,
            "template": record.message.template,
            "file": record.file,
            "line": record.line,
        ]
        if !record.fields.isEmpty {
            var fields: [String: String] = [:]
            for (key, value) in record.fields { fields[key.rawValue] = value.text }
            object["fields"] = fields
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func write(_ data: Data) {
        guard ensureHandle() else { return }
        state.withLock { current in
            guard let handle = current.handle else { return }
            do {
                try handle.write(contentsOf: data)
                current.bytesWritten += data.count
                if current.bytesWritten >= maxFileBytes {
                    try? handle.close()
                    current.handle = nil
                    current.bytesWritten = 0
                    current.rotation += 1
                }
            } catch {
                current.disabled = true
                try? handle.close()
                current.handle = nil
            }
        }
    }

    private func ensureHandle() -> Bool {
        let needsHandle = state.withLock { !$0.disabled && $0.handle == nil }
        if !needsHandle { return state.withLock { !$0.disabled } }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            state.withLock { $0.disabled = true }
            return false
        }
        let url = currentFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                state.withLock { $0.disabled = true }
                return false
            }
        }
        do {
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            state.withLock {
                $0.handle = opened
                $0.bytesWritten = size
            }
            return true
        } catch {
            state.withLock { $0.disabled = true }
            return false
        }
    }
}
