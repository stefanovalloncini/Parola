import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher baseline across launches", .tags(.fileSystem))
struct FolderWatcherBaselineTests {
    private typealias Fixture = WatchedFolderFixture

    private func makeWatcher(
        _ folder: URL,
        clock: FixedClock,
        scheduler: ManualScheduler,
        collected: CollectedURLs,
        onBaselineChange: (@Sendable () -> Void)? = nil
    ) -> FolderWatcher {
        let options = FolderWatcher.Options(
            recursive: true,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        return FolderWatcher(folderURL: folder, options: options, onBaselineChange: onBaselineChange) {
            collected.append($0)
        }
    }

    @Test("a file added while the watcher was stopped arrives when it starts from its baseline")
    func quitAddRestartEmits() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("old.m4a"), clock: clock)

        let collected = CollectedURLs()
        let before = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: collected)
        await before.start()
        let saved = try #require(await before.baseline())
        await before.stop()
        #expect(saved.entries.map(\.path) == ["old.m4a"])

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Later"), withIntermediateDirectories: true)
        try Fixture.writeSettled(folder.appendingPathComponent("while-quit.wav"), clock: clock)
        try Fixture.writeSettled(folder.appendingPathComponent("Later/nested.mp3"), clock: clock)

        let scheduler = ManualScheduler()
        let after = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await after.start(baseline: saved)
        #expect(Fixture.names(await after.pendingPaths) == ["while-quit.wav", "nested.mp3"])
        try await scheduler.advance(ticks: 2)
        await after.stop()

        #expect(Set(collected.snapshot().map(\.lastPathComponent)) == ["while-quit.wav", "nested.mp3"])
    }

    @Test("a folder started without a baseline treats everything already in it as seen")
    func newFolderEmitsNothingOld() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        for name in ["a.m4a", "b.wav", "Archive/c.mov"] {
            try Fixture.writeSettled(folder.appendingPathComponent(name), clock: clock)
        }

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()
        #expect(await watcher.pendingPaths.isEmpty)
        #expect(await watcher.baseline()?.entries.map(\.path) == ["Archive/c.mov", "a.m4a", "b.wav"])

        try Fixture.writeSettled(folder.appendingPathComponent("new.m4a"), clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 2)
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["new.m4a"])
    }

    @Test("a baseline read back from JSON still matches after the folder was renamed")
    func baselineSurvivesCodingAndRootRename() async throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("kept.m4a"), clock: clock)

        let collected = CollectedURLs()
        let before = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: collected)
        await before.start()
        let data = try JSONEncoder().encode(try #require(await before.baseline()))
        await before.stop()

        let renamed = parent.appendingPathComponent("Recordings")
        try FileManager.default.moveItem(at: folder, to: renamed)
        try Fixture.writeSettled(renamed.appendingPathComponent("fresh.wav"), clock: clock)

        let scheduler = ManualScheduler()
        let after = makeWatcher(renamed, clock: clock, scheduler: scheduler, collected: collected)
        await after.start(baseline: try JSONDecoder().decode(FolderWatcher.Baseline.self, from: data))
        try await scheduler.advance(ticks: 2)
        await after.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["fresh.wav"])
    }

    @Test("a file still settling when the watcher stops is left out of the baseline, so it arrives after a restart")
    func settlingFileIsNotBaselined() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())

        let collected = CollectedURLs()
        let before = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: collected)
        await before.start()
        try Fixture.writeSettled(folder.appendingPathComponent("settling.m4a"), clock: clock)
        await before.checkForNewFiles()
        #expect(Fixture.names(await before.pendingPaths) == ["settling.m4a"])
        let saved = try #require(await before.baseline())
        await before.stop()
        #expect(saved.entries.isEmpty)

        let scheduler = ManualScheduler()
        let after = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await after.start(baseline: saved)
        try await scheduler.advance(ticks: 2)
        await after.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["settling.m4a"])
    }

    @Test("the baseline change callback fires after the first scan and after an arrival settles")
    func baselineChangeIsReported() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let changes = OSAllocatedUnfairLock(initialState: 0)

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        let watcher = FolderWatcher(
            folderURL: folder,
            options: options,
            onBaselineChange: { changes.withLock { $0 += 1 } },
            onNewMediaFile: { collected.append($0) }
        )
        await watcher.start()
        #expect(changes.withLock { $0 } == 1)

        try Fixture.writeSettled(folder.appendingPathComponent("drop.wav"), clock: clock)
        await watcher.checkForNewFiles()
        #expect(changes.withLock { $0 } == 1, "a file still settling is not part of the baseline yet")

        try await scheduler.advanceAndWait()
        #expect(changes.withLock { $0 } == 1, "one steady check is not enough")
        try await scheduler.advanceAndWait()
        #expect(changes.withLock { $0 } == 2)
        await watcher.checkForNewFiles()
        #expect(changes.withLock { $0 } == 2, "a rescan that finds nothing new changes nothing")
        await watcher.stop()
        #expect(collected.snapshot().count == 1)
    }

    @Test("until its first scan lands, a watcher's baseline is the one it started with, or nil")
    func baselineBeforeTheFirstScan() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("old.m4a"), clock: clock)
        let parked = DispatchQueue(label: "parola.test.parked-scan")
        parked.suspend()
        let options = FolderWatcher.Options(clock: clock, scheduler: ManualScheduler(), scanQueue: parked)
        let seed = FolderWatcher.Baseline(entries: [
            .init(path: "old.m4a", inode: 1, size: 1024, modified: clock.start, emittedAt: nil),
        ])

        let unseeded = FolderWatcher(folderURL: folder, options: options) { _ in }
        let seeded = FolderWatcher(folderURL: folder, options: options) { _ in }
        let first = Task { await unseeded.start() }
        let second = Task { await seeded.start(baseline: seed) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await seeded.baseline() != seed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await unseeded.baseline() == nil)
        #expect(await seeded.baseline() == seed)

        parked.resume()
        await first.value
        await second.value
        #expect(await unseeded.baseline()?.entries.map(\.path) == ["old.m4a"])
        await unseeded.stop()
        await seeded.stop()
    }
}
