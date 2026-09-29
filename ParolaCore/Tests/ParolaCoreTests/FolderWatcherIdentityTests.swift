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
        fileSystem: String? = nil,
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
        if let fileSystem {
            options.fileSystemName = { _ in fileSystem }
        }
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
        try await scheduler.advance(ticks: 3)
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
        try await secondScheduler.advance(ticks: 3)

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
        try await scheduler.advance(ticks: 3)
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
        let saved = try #require(await watcher.baseline())

        try FileManager.default.moveItem(at: away, to: folder)
        try Fixture.writeSettled(folder.appendingPathComponent("fresh.mp3"), clock: clock)
        let scheduler = ManualScheduler()
        let resumed = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await resumed.start(baseline: saved)
        #expect(Fixture.names(await resumed.pendingPaths) == ["fresh.mp3"])
        try await scheduler.advance(ticks: 3)
        await resumed.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["fresh.mp3"])
    }

    @Test(
        "under a reused inode, the birth time tells a new file from an old one; APFS never reuses inodes",
        arguments: [("msdos", ["renamed.wav", "same-name.wav", "older-birth.wav"]), ("apfs", [])]
    )
    func reusedInodeIsANewFile(fileSystem: String, arrivals: [String]) async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let names = ["renamed.wav", "same-name.wav", "same-file.wav", "old-baseline.wav", "backdated.wav", "shifted.wav", "older-birth.wav"]
        for name in names {
            try Fixture.writeSettled(folder.appendingPathComponent(name), clock: clock)
        }
        try FileManager.default.setAttributes(
            [.creationDate: clock.start.addingTimeInterval(-5000)],
            ofItemAtPath: folder.appendingPathComponent("older-birth.wav").path
        )
        let info = try names.map { try #require(FolderWatcher.FileInfo(folder.appendingPathComponent($0).path)) }
        let otherBirth = clock.start.addingTimeInterval(-86_400)
        let seed = FolderWatcher.Baseline(entries: [
            .init(path: "ZOOM0001.WAV", inode: info[0].inode, size: 99, modified: otherBirth, created: otherBirth),
            .init(path: "same-name.wav", inode: info[1].inode, size: info[1].size, modified: info[1].modified, created: otherBirth),
            .init(path: "same-file.wav", inode: info[2].inode, size: info[2].size, modified: info[2].modified, created: info[2].birth),
            .init(path: "old-baseline.wav", inode: info[3].inode, size: info[3].size, modified: info[3].modified),
            .init(path: "backdated.wav", inode: info[4].inode, size: info[4].size, modified: info[4].modified,
                  created: info[4].created.addingTimeInterval(3600)),
            .init(path: "shifted.wav", inode: info[5].inode, size: info[5].size, modified: info[5].modified.addingTimeInterval(-3600),
                  created: info[5].created.addingTimeInterval(-3600)),
            .init(path: "older-birth.wav", inode: info[6].inode, size: info[6].size, modified: info[6].modified,
                  created: info[6].created.addingTimeInterval(3600)),
        ])

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(
            folder, clock: clock, scheduler: scheduler, observesFileSystem: false, fileSystem: fileSystem, collected: collected
        )
        await watcher.start(baseline: seed)
        #expect(Fixture.names(await watcher.pendingPaths) == Set(arrivals))
        if !arrivals.isEmpty {
            try await scheduler.advance(ticks: 3)
        }
        await watcher.stop()

        #expect(Set(collected.snapshot().map(\.lastPathComponent)) == Set(arrivals))
    }

    @Test(
        "on a volume that reuses inodes, only a time-zone-sized shift of both dates keeps an unedited file the same",
        arguments: [
            (231 * 86_400.0, true),
            (3600.0, false),
            (3607.0, true),
            (27 * 3600.0, true),
        ]
    )
    func shiftedDatesOnAReusedInode(shift: TimeInterval, arrives: Bool) async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let recording = folder.appendingPathComponent("ZOOM0001.WAV")
        try Fixture.writeSettled(recording, clock: clock)
        let dated = Date(timeIntervalSince1970: (clock.start.timeIntervalSince1970 - 3600).rounded())
        try FileManager.default.setAttributes([.modificationDate: dated, .creationDate: dated], ofItemAtPath: recording.path)
        let info = try #require(FolderWatcher.FileInfo(recording.path))
        #expect(info.birth == info.modified, "an unedited recording")
        let earlier = info.modified.addingTimeInterval(-shift)
        let seed = FolderWatcher.Baseline(entries: [
            .init(path: "ZOOM0001.WAV", inode: info.inode, size: info.size, modified: earlier, created: earlier),
        ])

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(
            folder, clock: clock, scheduler: scheduler, observesFileSystem: false, fileSystem: "msdos", collected: collected
        )
        await watcher.start(baseline: seed)
        if arrives {
            try await scheduler.advance(ticks: 3)
        }
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == (arrives ? ["ZOOM0001.WAV"] : []))
    }

    @Test("a file that was already there, changed in place or saved again with its birth time, doesn't arrive; one replaced by a new file does")
    func sameFileSavedAgainVersusReplaced() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let firstBirth = Date(timeIntervalSince1970: (clock.start.timeIntervalSince1970 - 3600).rounded())
        for name in ["edited.m4a", "saved-again.m4a", "replaced.m4a"] {
            let url = folder.appendingPathComponent(name)
            try Fixture.writeSettled(url, clock: clock)
            try FileManager.default.setAttributes([.creationDate: firstBirth], ofItemAtPath: url.path)
        }

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, observesFileSystem: false, collected: collected)
        await watcher.start()

        let edited = try FileHandle(forWritingTo: folder.appendingPathComponent("edited.m4a"))
        try edited.seekToEnd()
        try edited.write(contentsOf: Data(count: 500))
        try edited.close()
        try replace(folder.appendingPathComponent("saved-again.m4a"), bytes: 3000, birth: firstBirth, clock: clock)
        try replace(folder.appendingPathComponent("replaced.m4a"), bytes: 3000, birth: firstBirth.addingTimeInterval(1800), clock: clock)
        await watcher.checkForNewFiles()

        #expect(Fixture.names(await watcher.pendingPaths) == ["replaced.m4a"])
        try await scheduler.advance(ticks: 3)
        let sizes = Dictionary(uniqueKeysWithValues: (await watcher.baseline()?.entries ?? []).map { ($0.path, $0.size) })
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["replaced.m4a"])
        #expect(sizes == ["edited.m4a": 1524, "saved-again.m4a": 3000, "replaced.m4a": 3000])
    }

    private func replace(_ url: URL, bytes: Int, birth: Date, clock: FixedClock) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        try Data(count: bytes).write(to: staging)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-5), .creationDate: birth],
            ofItemAtPath: staging.path
        )
        #expect(rename(staging.path, url.path) == 0)
    }
}
