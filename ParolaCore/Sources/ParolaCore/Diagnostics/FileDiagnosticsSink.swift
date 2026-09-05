import Foundation
import os

// fileState is mutated only inside closures dispatched onto fileQueue, its sole owner; every
// other stored property is immutable or lock-protected.
public final class FileDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {
    private struct BufferState {
        var buffer: [LogRecord] = []
        var dropped: Int = 0
        var disabled: Bool = false
    }

    private struct FileState {
        var handle: FileHandle?
        var bytesWritten: Int = 0
    }

    /// Stamped on every JSONL line. Bump it whenever the line's keys change, so a reader handed a
    /// file from an older build knows what shape to expect.
    public static let schemaVersion = 1

    /// Every file the sink writes starts with this, so a frontend deleting the store matches the
    /// same names the export reader does.
    public static let filePrefix = "parola-"

    private let bufferState = OSAllocatedUnfairLock(initialState: BufferState())
    private let rotationState = OSAllocatedUnfairLock(initialState: 0)
    private let sweepState = OSAllocatedUnfairLock(initialState: 0)
    private let fileQueue = DispatchQueue(label: "com.parola.diagnostics.file-sink")
    private var fileState = FileState()

    private let write: @Sendable (FileHandle, Data) throws -> Void
    private let directory: URL
    private let minimumLevel: LogLevel
    private let maxFileBytes: Int
    private let retentionDays: Int
    private let totalBudgetBytes: Int
    private let maxBufferedRecords: Int
    private let baseName: String

    public convenience init(
        directory: URL,
        minimumLevel: LogLevel = .info,
        maxFileBytes: Int = 5_000_000,
        retentionDays: Int = 7,
        totalBudgetBytes: Int = 10_000_000,
        maxBufferedRecords: Int = 4_096
    ) {
        self.init(
            directory: directory,
            minimumLevel: minimumLevel,
            maxFileBytes: maxFileBytes,
            retentionDays: retentionDays,
            totalBudgetBytes: totalBudgetBytes,
            maxBufferedRecords: maxBufferedRecords,
            write: { try $0.write(contentsOf: $1) }
        )
    }

    /// `write` exists so tests can reach the write-failure branch: once the handle is open, no
    /// portable filesystem trick makes `write(2)` fail.
    init(
        directory: URL,
        minimumLevel: LogLevel = .info,
        maxFileBytes: Int = 5_000_000,
        retentionDays: Int = 7,
        totalBudgetBytes: Int = 10_000_000,
        maxBufferedRecords: Int = 4_096,
        write: @escaping @Sendable (FileHandle, Data) throws -> Void
    ) {
        self.write = write
        self.directory = directory
        self.minimumLevel = minimumLevel
        self.maxFileBytes = maxFileBytes
        self.retentionDays = retentionDays
        self.totalBudgetBytes = totalBudgetBytes
        self.maxBufferedRecords = maxBufferedRecords
        let pid = ProcessInfo.processInfo.processIdentifier
        let epoch = Int(Date().timeIntervalSince1970)
        // The token keeps two sinks built in the same second apart: they would otherwise share a
        // base name, and the trim's identity exemption would let one delete the other's open file.
        let token = String(UInt32.random(in: 0..<0x1_0000), radix: 16)
        self.baseName = "\(Self.filePrefix)\(pid)-\(epoch)-\(token)"
        scheduleSweep()
    }

    /// A queued drain holds a strong `self`, so deinit only runs once the file queue is idle and
    /// touching `fileState` from here is safe.
    deinit {
        drainOnQueue()
        try? fileState.handle?.close()
    }

    private func scheduleSweep() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let outcome = self?.sweep(now: Date()), outcome.overBudget else { return }
            ParolaLog.notice(
                .diagnostics,
                "diagnostics sweep finished over budget",
                [
                    .bytes: .bytes(Int64(outcome.bytesRemaining)),
                    .count: .int(outcome.skippedLive),
                    .rotations: .int(outcome.ownRotations),
                ]
            )
        }
    }

    public var isDisabled: Bool { bufferState.withLock { $0.disabled } }

    var completedSweeps: Int { sweepState.withLock { $0 } }

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
            guard current.buffer.count < maxBufferedRecords else {
                current.dropped += 1
                return true
            }
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

    /// Writes what is buffered, then closes the current file and points the sink at a fresh one.
    /// A caller that deletes the files on disk has to call this first: the sink holds its file
    /// open, so deleting underneath it would send every later record into an unlinked inode.
    public func startNewFile() async {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                self.drainOnQueue()
                try? self.fileState.handle?.close()
                self.fileState.handle = nil
                self.fileState.bytesWritten = 0
                self.rotationState.withLock { $0 += 1 }
                continuation.resume()
            }
        }
    }

    /// Blocks the caller until the buffer is on disk. Never call it from `fileQueue` itself:
    /// `DispatchQueue.sync` re-entered from its own queue deadlocks.
    public func flushSynchronously() {
        fileQueue.sync { drainOnQueue() }
    }

    private func drainOnQueue() {
        let pending: (records: [LogRecord], dropped: Int) = bufferState.withLock { current in
            guard !current.disabled else { return ([], 0) }
            let taken = (current.buffer, current.dropped)
            current.buffer = []
            current.dropped = 0
            return taken
        }
        guard !pending.records.isEmpty || pending.dropped > 0 else { return }

        var payload = Data()
        for record in pending.records {
            guard let line = Self.encode(record) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        if pending.dropped > 0, let line = Self.encode(Self.dropNotice(pending.dropped)) {
            payload.append(line)
            payload.append(0x0A)
        }
        writeOnQueue(payload)
    }

    private static func dropNotice(_ count: Int) -> LogRecord {
        LogRecord(
            timestamp: Date(),
            level: .notice,
            subsystem: LogCategory.diagnostics.subsystem,
            category: .diagnostics,
            message: "diagnostics buffer full, records dropped",
            fields: [.count: .int(count)],
            file: "FileDiagnosticsSink.swift",
            line: 0
        )
    }

    private static func encode(_ record: LogRecord) -> Data? {
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "ts": LogTimestamp.string(from: record.timestamp),
            "level": record.level.name,
            "subsystem": record.subsystem.rawValue,
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
            try write(handle, data)
            fileState.bytesWritten += data.count
            if fileState.bytesWritten >= maxFileBytes {
                try? handle.close()
                fileState.handle = nil
                fileState.bytesWritten = 0
                rotationState.withLock { $0 += 1 }
                scheduleSweep()
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

    /// What one sweep did. `overBudget` means the trim ran out of files it was allowed to delete
    /// — every survivor is either the file still open here or a live sibling's — so the folder
    /// stays large. `ownRotations` is how many of the deletions were this sink's own rotations.
    struct SweepOutcome: Sendable, Equatable {
        var deleted = 0
        var skippedLive = 0
        var ownRotations = 0
        var bytesRemaining = 0
        var overBudget = false
    }

    @discardableResult
    func sweep(now: Date) -> SweepOutcome {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return SweepOutcome() }

        var outcome = SweepOutcome()

        let mine = entries.filter {
            $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "jsonl"
        }

        var surviving: [(url: URL, date: Date, size: Int)] = []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        // Only the file still open is exempt: this sink's earlier rotations are closed, complete
        // and ours to trim.
        let openFile = currentFileName
        for url in mine {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? now
            let size = values?.fileSize ?? 0
            if date < cutoff && url.lastPathComponent != openFile {
                try? manager.removeItem(at: url)
                if manager.fileExists(atPath: url.path) {
                    surviving.append((url, date, size))
                } else {
                    outcome.deleted += 1
                    if url.lastPathComponent.hasPrefix(baseName) { outcome.ownRotations += 1 }
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
            if name == openFile {
                index += 1
                continue
            }
            // Our own pid is live, so the liveness skip has to let our closed rotations through.
            if !name.hasPrefix(baseName), Self.isOwnedByLiveProcess(name) {
                outcome.skippedLive += 1
                index += 1
                continue
            }
            do {
                try manager.removeItem(at: candidate.url)
                total -= candidate.size
                outcome.deleted += 1
                if name.hasPrefix(baseName) { outcome.ownRotations += 1 }
            } catch {
            }
            index += 1
        }

        outcome.bytesRemaining = total
        outcome.overBudget = total > totalBudgetBytes
        sweepState.withLock { $0 += 1 }
        return outcome
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
