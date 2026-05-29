import Foundation
import CryptoKit

struct RevisionEntry: Sendable {
    let revision: Int
    let timestamp: Date
    let cause: String
    let snapshotHash: String

    var automationValue: AutomationValue {
        .object([
            "revision": .int(revision),
            "timestamp": .string(timestamp.ISO8601Format()),
            "cause": .string(cause),
            "snapshotHash": .string(snapshotHash),
        ])
    }
}

actor RevisionLog {
    private var entries: [RevisionEntry] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
        entries.reserveCapacity(capacity + 1)
    }

    func append(_ entry: RevisionEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func recent(count: Int) -> [RevisionEntry] {
        let take = max(0, min(count, entries.count))
        return Array(entries.suffix(take))
    }

    func since(_ revision: Int) -> [RevisionEntry] {
        entries.filter { $0.revision > revision }
    }

    static func hash(_ value: AutomationValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.jsonObject, options: [.sortedKeys]) else {
            return ""
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
