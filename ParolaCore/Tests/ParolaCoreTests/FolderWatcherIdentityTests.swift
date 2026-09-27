import Foundation
import Testing
@testable import ParolaCore

@Suite("FolderWatcher file identity", .tags(.fileSystem))
struct FolderWatcherIdentityTests {
    private typealias Fixture = WatchedFolderFixture

    private func makeWatcher(
        _ folder: URL,
        clock: FixedClock,
        scheduler: ManualScheduler,
        ledger: FolderWatcherLedger = FolderWatcherLedger(),
        observesFileSystem: Bool = true,
        collected: CollectedURLs
    ) -> FolderWatcher {
        var options = FolderWatcher.Options(
            recursive: true,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler,
            ledger: ledger
        )
        options.observesFileSystem = observesFileSystem
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    @Test("renaming a file already in the folder or one already emitted is not an arrival")
    func renameKeepsIdentity() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("Recording 12.m4a"), clock: clock)

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        try Fixture.writeSettled(folder.appendingPathComponent("drop.wav"), clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 2)
        #expect(collected.snapshot().map(\.lastPathComponent) == ["drop.wav"])

        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("Recording 12.m4a"),
            to: folder.appendingPathComponent("Standup.m4a")
        )
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("drop.wav"),
            to: folder.appendingPathComponent("Interview.wav")
        )
        await watcher.checkForNewFiles()

        #expect(await watcher.pendingPaths.isEmpty)
        #expect(Fixture.names(await watcher.trackedPaths) == ["Standup.m4a", "Interview.wav"])
        await watcher.stop()
        #expect(collected.snapshot().count == 1)
    }

    @Test("moving files into a subfolder of the watched tree is not an arrival")
    func moveIntoSubfolderKeepsIdentity() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        for name in ["a.m4a", "b.mp3", "c.mov"] {
            try Fixture.writeSettled(folder.appendingPathComponent(name), clock: clock)
        }

        let collected = CollectedURLs()
        let watcher = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: collected)
        await watcher.start()

        let done = folder.appendingPathComponent("Done")
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        for name in ["a.m4a", "b.mp3", "c.mov"] {
            try FileManager.default.moveItem(at: folder.appendingPathComponent(name), to: done.appendingPathComponent(name))
        }
        await watcher.checkForNewFiles()

        #expect(await watcher.pendingPaths.isEmpty)
        let tracked = await watcher.trackedPaths
        #expect(tracked.count == 3)
        #expect(tracked.allSatisfy { $0.contains("/Done/") })
        await watcher.stop()
        #expect(collected.snapshot().isEmpty)
    }

    @Test("a file moved between two watched folders is handed over, whichever folder rescans first")
    func moveBetweenWatchedFolders() async throws {
        let first = try Fixture.makeTempDir()
        let second = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(first.appendingPathComponent("early.m4a"), clock: clock)
        try Fixture.writeSettled(first.appendingPathComponent("late.m4a"), clock: clock)

        let ledger = FolderWatcherLedger()
        let collected = CollectedURLs()
        let firstScheduler = ManualScheduler()
        let secondScheduler = ManualScheduler()
        let source = makeWatcher(
            first, clock: clock, scheduler: firstScheduler, ledger: ledger, observesFileSystem: false, collected: collected
        )
        let target = makeWatcher(
            second, clock: clock, scheduler: secondScheduler, ledger: ledger, observesFileSystem: false, collected: collected
        )
        await source.start()
        await target.start()

        try FileManager.default.moveItem(at: first.appendingPathComponent("early.m4a"), to: second.appendingPathComponent("early.m4a"))
        await source.checkForNewFiles()
        await target.checkForNewFiles()
        #expect(await target.pendingPaths.isEmpty, "the source folder handed the file over before the target saw it")

        try FileManager.default.moveItem(at: first.appendingPathComponent("late.m4a"), to: second.appendingPathComponent("late.m4a"))
        await target.checkForNewFiles()
        #expect(Fixture.names(await target.pendingPaths) == ["late.m4a"])
        await source.checkForNewFiles()
        try await secondScheduler.advance(ticks: 2)

        #expect(await target.pendingPaths.isEmpty)
        #expect(Fixture.names(await target.trackedPaths) == ["early.m4a", "late.m4a"])
        #expect(await source.trackedPaths.isEmpty)
        await source.stop()
        await target.stop()
        #expect(collected.snapshot().isEmpty)
    }

    @Test("a file moved in from outside any watched folder is still an arrival")
    func moveFromOutsideIsAnArrival() async throws {
        let folder = try Fixture.makeTempDir()
        let outside = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(outside.appendingPathComponent("memo.m4a"), clock: clock)

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        try FileManager.default.moveItem(at: outside.appendingPathComponent("memo.m4a"), to: folder.appendingPathComponent("memo.m4a"))
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 2)
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["memo.m4a"])
    }

    @Test("a scan that finds the watched folder missing reports it lost and keeps what it knew")
    func rootTemporarilyMissing() async throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Inbox")
        let away = parent.appendingPathComponent("Inbox (moved)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("one.m4a"), clock: clock)
        try Fixture.writeSettled(folder.appendingPathComponent("Nested/two.wav"), clock: clock)

        let collected = CollectedURLs()
        let watcher = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), observesFileSystem: false, collected: collected)
        await watcher.start()

        try FileManager.default.moveItem(at: folder, to: away)
        await watcher.checkForNewFiles()
        #expect(await watcher.state == .lost)
        #expect(Fixture.names(await watcher.trackedPaths) == ["one.m4a", "two.wav"])
        let saved = await watcher.baseline()

        try FileManager.default.moveItem(at: away, to: folder)
        try Fixture.writeSettled(folder.appendingPathComponent("fresh.mp3"), clock: clock)
        let scheduler = ManualScheduler()
        let resumed = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await resumed.start(baseline: saved)
        #expect(Fixture.names(await resumed.pendingPaths) == ["fresh.mp3"])
        try await scheduler.advance(ticks: 2)
        await resumed.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["fresh.mp3"])
    }
}
