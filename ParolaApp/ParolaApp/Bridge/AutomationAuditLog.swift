import Foundation
import ParolaCore

actor AutomationAuditLog {
    private static let filePrefix = "automation-audit-"

    private let directory: URL
    private let baseName: String
    private let retentionDays: Int
    private let totalBudgetBytes: Int
    private let rotateThreshold: Int
    private let timestampFormatter: ISO8601DateFormatter

    private var rotation: Int = 0
    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private var disabled: Bool = false

    init(
        cacheDir: URL? = nil,
        retentionDays: Int = 7,
        totalBudgetBytes: Int = 10_000_000,
        rotateThreshold: Int = 5 * 1024 * 1024
    ) {
        let resolved: URL
        if let cacheDir {
            resolved = cacheDir
        } else {
            let caches = (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            resolved = caches.appendingPathComponent("Parola", isDirectory: true)
        }
        self.directory = resolved
        self.retentionDays = retentionDays
        self.totalBudgetBytes = totalBudgetBytes
        self.rotateThreshold = rotateThreshold
        let pid = ProcessInfo.processInfo.processIdentifier
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        self.baseName = "\(Self.filePrefix)\(pid)-\(startedAtUnix)"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = formatter
    }

    func record(
        id: String,
        command: String,
        args: AutomationArgs,
        ok: Bool,
        elapsedMs: Int,
        errorCode: String? = nil
    ) {
        guard !disabled else { return }

        var entry: [String: Any] = [
            "ts": timestampFormatter.string(from: Date()),
            "id": id,
            "cmd": command,
            "args": serializedArgs(args),
            "ok": ok,
            "elapsedMs": elapsedMs,
        ]
        if let errorCode { entry["errorCode"] = errorCode }

        guard let payload = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }

        var line = payload
        line.append(0x0A)
        append(line)
    }

    private func serializedArgs(_ args: AutomationArgs) -> Any {
        AutomationValue.object(args.values).jsonObject
    }

    private func append(_ data: Data) {
        guard ensureHandle() else { return }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            if bytesWritten >= rotateThreshold {
                rotate()
            }
        } catch {
            disabled = true
            try? handle.close()
            self.handle = nil
        }
    }

    private func ensureHandle() -> Bool {
        if handle != nil { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            disabled = true
            return false
        }
        let url = currentFileURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                disabled = true
                return false
            }
        }
        do {
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
            bytesWritten = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return true
        } catch {
            disabled = true
            return false
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        rotation += 1
        // The rotation just closed is now trimmable, and a session that never quits sweeps no other way.
        sweep()
    }

    func currentFileURL() -> URL {
        let name = rotation == 0 ? "\(baseName).jsonl" : "\(baseName)-\(rotation).jsonl"
        return directory.appendingPathComponent(name)
    }

    /// What one sweep did. `overBudget` means the trim ran out of files it was allowed to delete
    /// — every survivor is either this instance's or a live sibling's — so the folder stays large.
    struct SweepOutcome: Sendable, Equatable {
        var deleted = 0
        var skippedLive = 0
        var bytesRemaining = 0
        var overBudget = false
    }

    @discardableResult
    func sweep(now: Date = Date()) -> SweepOutcome {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return SweepOutcome() }

        var outcome = SweepOutcome()
        var surviving: [(url: URL, date: Date, size: Int)] = []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        // Only the file still open is exempt: this process's earlier rotations are closed, complete and ours to trim.
        let openFile = currentFileURL().lastPathComponent
        let mine = entries.filter {
            $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "jsonl"
        }

        for url in mine {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? now
            let size = values?.fileSize ?? 0
            guard date < cutoff, url.lastPathComponent != openFile else {
                surviving.append((url, date, size))
                continue
            }
            try? manager.removeItem(at: url)
            if manager.fileExists(atPath: url.path) {
                surviving.append((url, date, size))
            } else {
                outcome.deleted += 1
            }
        }

        surviving.sort { $0.date < $1.date }
        var total = surviving.reduce(0) { $0 + $1.size }
        var index = 0
        while total > totalBudgetBytes, index < surviving.count {
            let candidate = surviving[index]
            index += 1
            let name = candidate.url.lastPathComponent
            if name == openFile { continue }
            if !name.hasPrefix(baseName), Self.isOwnedByLiveProcess(name) {
                outcome.skippedLive += 1
                continue
            }
            guard (try? manager.removeItem(at: candidate.url)) != nil else { continue }
            total -= candidate.size
            outcome.deleted += 1
        }

        outcome.bytesRemaining = total
        outcome.overBudget = total > totalBudgetBytes
        if outcome.overBudget {
            ParolaLog.notice(
                .appBridge,
                "automation audit sweep finished over budget",
                [.bytes: .bytes(Int64(total)), .count: .int(outcome.skippedLive)]
            )
        }
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

    deinit {
        try? handle?.close()
    }
}
