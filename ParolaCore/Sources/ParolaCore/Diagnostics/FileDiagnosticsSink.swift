import Foundation
import os

// fileState is mutated only inside closures dispatched onto fileQueue, its sole owner; every
// other stored property is immutable or lock-protected.
public final class FileDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {
    private struct BufferState {
        var buffer: [LogRecord] = []
        var disabled: Bool = false
    }

    private struct FileState {
        var handle: FileHandle?
        var bytesWritten: Int = 0
    }

    private static let filePrefix = "parola-"

    private let bufferState = OSAllocatedUnfairLock(initialState: BufferState())
    private let rotationState = OSAllocatedUnfairLock(initialState: 0)
    private let fileQueue = DispatchQueue(label: "com.parola.diagnostics.file-sink")
    private var fileState = FileState()

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
        self.baseName = "\(Self.filePrefix)\(pid)-\(epoch)"
        DispatchQueue.global(qos: .utility).async { self.sweep(now: Date()) }
    }

    public var isDisabled: Bool { bufferState.withLock { $0.disabled } }

    public var currentFileURL: URL {
        directory.appendingPathComponent(currentFileName)
    }

    private var currentFileName: String {
        let rotation = rotationState.withLock { $0 }
        return rotation == 0 ? "\(baseName).jsonl" : "\(baseName)-\(rotation).jsonl"
    }

    public func enqueue(_ record: LogRecord) {
        guard record.level >= minimumLevel else { return }
        let shouldDrainNow: Bool = bufferState.withLock { current in
            guard !current.disabled else { return false }
            current.buffer.append(record)
            return record.level >= .error || current.buffer.count >= 64
        }
        guard shouldDrainNow else { return }
        fileQueue.async { self.drainOnQueue() }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                self.drainOnQueue()
                continuation.resume()
            }
        }
    }

    private func drainOnQueue() {
        let pending: [LogRecord] = bufferState.withLock { current in
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
        writeOnQueue(payload)
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

    private func writeOnQueue(_ data: Data) {
        guard ensureHandleOnQueue(), let handle = fileState.handle else { return }
        do {
            try handle.write(contentsOf: data)
            fileState.bytesWritten += data.count
            if fileState.bytesWritten >= maxFileBytes {
                try? handle.close()
                fileState.handle = nil
                fileState.bytesWritten = 0
                rotationState.withLock { $0 += 1 }
            }
        } catch {
            bufferState.withLock { $0.disabled = true }
            try? handle.close()
            fileState.handle = nil
        }
    }

    private func ensureHandleOnQueue() -> Bool {
        if fileState.handle != nil { return true }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            bufferState.withLock { $0.disabled = true }
            return false
        }
        let url = directory.appendingPathComponent(currentFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                bufferState.withLock { $0.disabled = true }
                return false
            }
        }
        do {
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            fileState.handle = opened
            fileState.bytesWritten = size
            return true
        } catch {
            bufferState.withLock { $0.disabled = true }
            return false
        }
    }

    func sweep(now: Date) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let mine = entries.filter {
            $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "jsonl"
        }

        var surviving: [(url: URL, date: Date, size: Int)] = []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        for url in mine {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? now
            let size = values?.fileSize ?? 0
            if date < cutoff && !url.lastPathComponent.hasPrefix(baseName) {
                try? manager.removeItem(at: url)
                if manager.fileExists(atPath: url.path) {
                    surviving.append((url, date, size))
                }
            } else {
                surviving.append((url, date, size))
            }
        }

        surviving.sort { $0.date < $1.date }
        var total = surviving.reduce(0) { $0 + $1.size }
        var index = 0
        while total > totalBudgetBytes, index < surviving.count {
            let candidate = surviving[index]
            let name = candidate.url.lastPathComponent
            if !name.hasPrefix(baseName), !Self.isOwnedByLiveProcess(name) {
                do {
                    try manager.removeItem(at: candidate.url)
                    total -= candidate.size
                } catch {
                }
            }
            index += 1
        }
    }

    /// A sibling process still holding its log open would keep writing into an unlinked inode, so
    /// the budget trim skips it. A recycled pid can spare a dead process's file until the age
    /// cutoff — which runs no liveness check — catches it.
    private static func isOwnedByLiveProcess(_ fileName: String) -> Bool {
        guard fileName.hasPrefix(filePrefix) else { return false }
        let rest = fileName.dropFirst(filePrefix.count)
        guard let separator = rest.firstIndex(of: "-"),
              let pid = pid_t(rest[rest.startIndex..<separator]),
              pid > 0
        else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
