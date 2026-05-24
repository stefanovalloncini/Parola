import Foundation
import Darwin

struct BridgeDiscovery: Sendable {
    struct Record: Codable, Sendable {
        let port: UInt16
        let token: String
        let pid: Int
        let startedAt: Date
        let serverVersion: Int
    }

    let directory: URL

    init(cacheDir: URL? = nil) {
        if let cacheDir {
            self.directory = cacheDir
        } else {
            let caches = (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
            self.directory = caches.appendingPathComponent("Parola", isDirectory: true)
        }
    }

    var fileURL: URL { directory.appendingPathComponent("bridge.json") }

    func write(port: UInt16, token: String, pid: Int, startedAt: Date, serverVersion: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Record(port: port, token: token, pid: pid, startedAt: startedAt, serverVersion: serverVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601))
        }
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func read() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            return try Date(s, strategy: .iso8601)
        }
        guard let record = try? decoder.decode(Record.self, from: data) else { return nil }
        guard Self.isProcessAlive(pid: record.pid) else { return nil }
        return record
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func isProcessAlive(pid: Int) -> Bool {
        let result = kill(pid_t(pid), 0)
        if result == 0 { return true }
        return errno == EPERM
    }
}
