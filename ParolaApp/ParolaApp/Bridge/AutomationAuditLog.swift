import Foundation

actor AutomationAuditLog {
    private static let rotateThreshold: Int = 100 * 1024 * 1024

    private let directory: URL
    private let pid: Int
    private let startedAtUnix: Int
    private let timestampFormatter: ISO8601DateFormatter

    private var rotation: Int = 0
    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private var disabled: Bool = false

    init(cacheDir: URL? = nil) {
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
        self.pid = Int(ProcessInfo.processInfo.processIdentifier)
        self.startedAtUnix = Int(Date().timeIntervalSince1970)
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
            if bytesWritten >= Self.rotateThreshold {
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
    }

    private func currentFileURL() -> URL {
        let base = "automation-audit-\(pid)-\(startedAtUnix)"
        let name = rotation == 0 ? "\(base).jsonl" : "\(base)-\(rotation).jsonl"
        return directory.appendingPathComponent(name)
    }

    deinit {
        try? handle?.close()
    }
}
