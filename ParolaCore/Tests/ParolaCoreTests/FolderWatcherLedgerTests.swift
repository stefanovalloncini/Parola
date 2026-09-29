import Foundation
import Testing
@testable import ParolaCore

@Suite("FolderWatcher ledger")
struct FolderWatcherLedgerTests {
    private func departure(_ index: Int, at date: Date) -> FolderWatcherLedger.Departure {
        .init(size: Int64(index), modified: date, created: nil, status: .existing, departedAt: date)
    }

    @Test("a subtree of 20,000 files leaves in one batch, and every file can be claimed back")
    func largeBatchDeparts() {
        let ledger = FolderWatcherLedger()
        let now = Date()
        let batch = Dictionary(uniqueKeysWithValues: (0..<20_000).map { (FolderWatcher.FileKey(inode: UInt64($0)), departure($0, at: now)) })

        let started = ContinuousClock.now
        ledger.depart(batch, now: now)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(ledger.count == 20_000)
        #expect(ledger.claim(FolderWatcher.FileKey(inode: 19_999), size: 19_999, modified: now, created: nil, now: now) != nil)
        #expect(ledger.count == 19_999)
    }

    @Test("departures older than the retention are pruned by the next batch and can't be claimed")
    func oldDeparturesArePruned() {
        let ledger = FolderWatcherLedger(retention: .seconds(60))
        let start = Date()
        ledger.depart([FolderWatcher.FileKey(inode: 1): departure(1, at: start)], now: start)
        let later = start.addingTimeInterval(120)
        #expect(ledger.claim(FolderWatcher.FileKey(inode: 1), size: 1, modified: start, created: nil, now: later) == nil)

        ledger.depart([FolderWatcher.FileKey(inode: 2): departure(2, at: later)], now: later)
        #expect(ledger.count == 1)
    }
}
