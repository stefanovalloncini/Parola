import Foundation
import Testing
@testable import Parola

@Suite("RevisionLog ring buffer")
struct RevisionLogTests {

    private func makeEntry(_ revision: Int, cause: String = "test") -> RevisionEntry {
        RevisionEntry(
            revision: revision,
            timestamp: Date(timeIntervalSince1970: TimeInterval(revision)),
            cause: cause,
            snapshotHash: "hash-\(revision)"
        )
    }

    @Test("recent(count:) returns the requested entries in FIFO order")
    func recentReturnsFifo() async {
        let log = RevisionLog()
        for index in 1...5 {
            await log.append(makeEntry(index))
        }
        let last3 = await log.recent(count: 3)
        #expect(last3.map(\.revision) == [3, 4, 5])

        let last1 = await log.recent(count: 1)
        #expect(last1.map(\.revision) == [5])
    }

    @Test("recent(count:) clamps when fewer entries exist")
    func recentClampsWhenSparse() async {
        let log = RevisionLog()
        await log.append(makeEntry(1))
        await log.append(makeEntry(2))

        let many = await log.recent(count: 1000)
        #expect(many.count == 2)
        #expect(many.map(\.revision) == [1, 2])

        let none = await log.recent(count: 0)
        #expect(none.isEmpty)
    }

    @Test("since(revision:) returns only entries with revision > given")
    func sinceFiltersStrictlyGreater() async {
        let log = RevisionLog()
        for index in 1...4 {
            await log.append(makeEntry(index))
        }

        let after2 = await log.since(2)
        #expect(after2.map(\.revision) == [3, 4])

        let afterAll = await log.since(99)
        #expect(afterAll.isEmpty)

        let fromStart = await log.since(0)
        #expect(fromStart.map(\.revision) == [1, 2, 3, 4])
    }

    @Test("capacity cap drops the oldest entries once exceeded")
    func capacityDropsOldest() async {
        let log = RevisionLog(capacity: 3)
        for index in 1...5 {
            await log.append(makeEntry(index))
        }
        let all = await log.recent(count: 100)
        #expect(all.map(\.revision) == [3, 4, 5])
    }

    @Test("RevisionEntry.automationValue carries the four expected keys")
    func entryJsonHasFourKeys() {
        let entry = makeEntry(7, cause: "loadEntry")
        guard case .object(let dict) = entry.automationValue else {
            Issue.record("expected .object")
            return
        }
        #expect(Set(dict.keys) == Set(["revision", "timestamp", "cause", "snapshotHash"]))
        #expect(dict["revision"] == .int(7))
        #expect(dict["cause"] == .string("loadEntry"))
        #expect(dict["snapshotHash"] == .string("hash-7"))
        if case .string(let stamp) = dict["timestamp"] {
            #expect(!stamp.isEmpty)
        } else {
            Issue.record("timestamp should be a string")
        }
    }

    @Test("hash() returns a 64-char hex SHA-256 of stable JSON")
    func hashIsSha256Hex() {
        let h1 = RevisionLog.hash(.object(["k": .string("x")]))
        let h2 = RevisionLog.hash(.object(["k": .string("x")]))
        let h3 = RevisionLog.hash(.object(["k": .string("y")]))

        #expect(h1.count == 64)
        #expect(h1 == h2)
        #expect(h1 != h3)
        #expect(h1.allSatisfy { $0.isHexDigit })
    }

    @Test("hash() is stable across equivalent object key orderings")
    func hashIsStableAcrossKeyOrder() {
        let a: AutomationValue = .object(["a": .int(1), "b": .int(2)])
        let b: AutomationValue = .object(["b": .int(2), "a": .int(1)])
        #expect(RevisionLog.hash(a) == RevisionLog.hash(b))
    }
}
