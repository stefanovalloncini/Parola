import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher rescans only the directories that changed", .tags(.fileSystem))
struct FolderWatcherDirtyDirectoryTests {
    private typealias Fixture = WatchedFolderFixture

    private func makeWatcher(
        _ folder: URL,
        clock: FixedClock,
        scheduler: ManualScheduler,
        observesFileSystem: Bool = false,
        collected: CollectedURLs
    ) -> FolderWatcher {
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = observesFileSystem
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    private func makeTree(_ clock: FixedClock, subfolders: [String]) throws -> URL {
        let folder = try Fixture.makeTempDir()
        for name in subfolders {
            let subfolder = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            try Fixture.writeSettled(subfolder.appendingPathComponent("\(name).m4a"), clock: clock)
            try Data("notes".utf8).write(to: subfolder.appendingPathComponent("\(name).txt"))
        }
        return folder
    }

    @Test("a change in one subfolder lists that subfolder and nothing else")
    func onlyTheDirtyDirectoryIsListed() async throws {
        let clock = FixedClock(start: Date())
        let folder = try makeTree(clock, subfolders: ["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: CollectedURLs())
        await watcher.start()
        #expect(await watcher.listedDirectoryCount == 4)
        #expect(Fixture.names(await watcher.trackedPaths) == ["A.m4a", "B.m4a", "C.m4a"], "only media is tracked")

        let subfolder = folder.appendingPathComponent("B")
        try Fixture.writeSettled(subfolder.appendingPathComponent("new.wav"), clock: clock)
        await watcher.markDirty([try realPath(subfolder)])

        #expect(await watcher.listedDirectoryCount == 5)
        #expect(Fixture.names(await watcher.pendingPaths) == ["new.wav"])
        await watcher.stop()
    }

    @Test("a folder moved in whole is walked once and its media arrives")
    func movedInFolderIsWalked() async throws {
        let clock = FixedClock(start: Date())
        let folder = try makeTree(clock, subfolders: ["A"])
        let outside = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let batch = outside.appendingPathComponent("Batch")
        try FileManager.default.createDirectory(at: batch.appendingPathComponent("Day 2"), withIntermediateDirectories: true)
        try Fixture.writeSettled(batch.appendingPathComponent("one.m4a"), clock: clock)
        try Fixture.writeSettled(batch.appendingPathComponent("Day 2/two.mp3"), clock: clock)

        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()
        let before = await watcher.listedDirectoryCount

        try FileManager.default.moveItem(at: batch, to: folder.appendingPathComponent("Batch"))
        await watcher.markDirty([try realPath(folder)])
        #expect(await watcher.listedDirectoryCount == before + 3, "the root, then Batch and Day 2 walked once")

        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(Set(collected.snapshot().map(\.lastPathComponent)) == ["one.m4a", "two.mp3"])
    }

    @Test("a renamed subfolder keeps its files and drops the old directory")
    func renamedSubfolderKeepsIdentity() async throws {
        let clock = FixedClock(start: Date())
        let folder = try makeTree(clock, subfolders: ["Inbox", "Other"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("Inbox/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Fixture.writeSettled(nested.appendingPathComponent("deep.wav"), clock: clock)

        let watcher = makeWatcher(folder, clock: clock, scheduler: ManualScheduler(), collected: CollectedURLs())
        await watcher.start()

        try FileManager.default.moveItem(at: folder.appendingPathComponent("Inbox"), to: folder.appendingPathComponent("Done"))
        await watcher.markDirty([try realPath(folder)])

        #expect(await watcher.pendingPaths.isEmpty)
        let tracked = await watcher.trackedPaths
        #expect(Fixture.names(tracked) == ["Inbox.m4a", "deep.wav", "Other.m4a"])
        #expect(tracked.filter { $0.contains("/Done/") }.count == 2)
        let directories = Set(await watcher.watchedDirectories.map { ($0 as NSString).lastPathComponent })
        #expect(directories.isSuperset(of: ["Done", "Nested", "Other"]))
        #expect(!directories.contains("Inbox"))
        await watcher.stop()
    }

    @Test("a subfolder deleted and recreated under the same name is listed again")
    func replacedSubfolderIsRescanned() async throws {
        let clock = FixedClock(start: Date())
        let folder = try makeTree(clock, subfolders: ["Drop"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let drop = folder.appendingPathComponent("Drop")
        try FileManager.default.removeItem(at: drop)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try Fixture.writeSettled(drop.appendingPathComponent("replacement.m4a"), clock: clock)
        await watcher.markDirty([try realPath(folder)])

        #expect(Fixture.names(await watcher.trackedPaths) == ["replacement.m4a"])
        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["replacement.m4a"])
    }

    @Test("a real file-system event rescans the folder it came from, not the whole tree")
    func fileSystemEventRescansItsDirectory() async throws {
        let clock = FixedClock(start: Date())
        let names = (1...12).map { "Folder \($0)" }
        let folder = try makeTree(clock, subfolders: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = makeWatcher(
            folder, clock: clock, scheduler: ManualScheduler(), observesFileSystem: true, collected: CollectedURLs()
        )
        await watcher.start()
        let before = await watcher.listedDirectoryCount
        #expect(before == 13)

        try Fixture.writeSettled(folder.appendingPathComponent("Folder 7/arrival.wav"), clock: clock)
        let deadline = ContinuousClock.now + .seconds(5)
        while await !Fixture.names(watcher.pendingPaths).contains("arrival.wav"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(Fixture.names(await watcher.pendingPaths) == ["arrival.wav"])
        let listed = await watcher.listedDirectoryCount - before
        #expect(listed >= 1 && listed < 4, "listed \(listed) directories for one event")
        await watcher.stop()
    }

    private func realPath(_ url: URL) throws -> String {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

@Suite("FolderWatcher when descriptors or listings run out", .tags(.fileSystem))
struct FolderWatcherResourceTests {
    private typealias Fixture = WatchedFolderFixture

    private final class Switch: Sendable {
        private let storage: OSAllocatedUnfairLock<Bool>
        init(_ isOn: Bool) { storage = OSAllocatedUnfairLock(initialState: isOn) }
        var isOn: Bool { storage.withLock { $0 } }
        func set(_ isOn: Bool) { storage.withLock { $0 = isOn } }
    }

    @Test("a folder whose source couldn't be opened is listed again on the settle tick and gets its source later")
    func unsourcedFolderIsRelisted() async throws {
        let clock = FixedClock(start: Date())
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let outOfDescriptors = Switch(true)
        let scheduler = ManualScheduler()
        let collected = CollectedURLs()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.openDirectory = { path in
            if outOfDescriptors.isOn, (path as NSString).lastPathComponent == "B" {
                return -1
            }
            return path.withCString { open($0, O_EVTONLY) }
        }
        let watcher = FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
        await watcher.start()
        #expect(await Fixture.names(watcher.sourcelessDirectories) == ["B"])

        try Fixture.writeSettled(folder.appendingPathComponent("B/no-event.wav"), clock: clock)
        try await scheduler.advanceAndWait()
        await watcher.markDirty([])
        #expect(Fixture.names(await watcher.pendingPaths) == ["no-event.wav"])

        outOfDescriptors.set(false)
        try await scheduler.advance(ticks: 3)
        await watcher.markDirty([])
        #expect(await watcher.sourcelessDirectories.isEmpty)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["no-event.wav"])
    }

    @Test("folders past the source budget are polled on a backoff, and their sources are given back on stop")
    func foldersPastTheBudgetArePolled() async throws {
        let clock = FixedClock(start: Date())
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["A", "B", "C"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let budget = FolderSourceBudget(limit: 1)
        let scheduler = ManualScheduler()
        let collected = CollectedURLs()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .seconds(1), clock: clock, scheduler: scheduler)
        options.sourceBudget = budget
        let watcher = FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
        await watcher.start()
        #expect(budget.inUse == 1)
        let polled = await watcher.sourcelessDirectories
        #expect(polled.count == 2)

        try await scheduler.advance(ticks: 4)
        #expect(await scheduler.intervals.map { $0.components.seconds } == [1, 2, 3, 5, 9])

        let quiet = try #require(polled.first)
        try Fixture.writeSettled(URL(fileURLWithPath: quiet).appendingPathComponent("unheard.wav"), clock: clock)
        try await scheduler.advanceAndWait()
        await watcher.markDirty([])
        #expect(Fixture.names(await watcher.pendingPaths) == ["unheard.wav"])
        try await scheduler.advance(ticks: 3)
        #expect(collected.snapshot().map(\.lastPathComponent) == ["unheard.wav"])

        await watcher.stop()
        let deadline = ContinuousClock.now + .seconds(5)
        while budget.inUse > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(budget.inUse == 0)
    }

    @Test("a listing of the watched folder that runs out of descriptors keeps the watch and is tried again")
    func failedRootListingIsRetried() async throws {
        let clock = FixedClock(start: Date())
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failing = Switch(false)
        let scheduler = ManualScheduler()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        options.lister = { path, recursive in
            failing.isOn ? .failed : FolderWatcher.list(path, recursive: recursive)
        }
        let watcher = FolderWatcher(folderURL: folder, options: options) { _ in }
        await watcher.start()

        failing.set(true)
        try Fixture.writeSettled(folder.appendingPathComponent("new.wav"), clock: clock)
        await watcher.checkForNewFiles()
        #expect(await watcher.state == .watching)
        #expect(await watcher.pendingPaths.isEmpty)

        failing.set(false)
        try await scheduler.advanceAndWait()
        await watcher.markDirty([])
        #expect(Fixture.names(await watcher.pendingPaths) == ["new.wav"])
        await watcher.stop()
    }

    @Test("only a missing directory counts as gone; any other listing error is worth another try")
    func listingErrorsAreSorted() throws {
        let folder = try Fixture.makeTempDir()
        let locked = folder.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        if case .listed = FolderWatcher.list(folder.path, recursive: true) {} else { Issue.record("an existing folder lists") }
        if case .missing = FolderWatcher.list(folder.appendingPathComponent("gone").path, recursive: true) {} else {
            Issue.record("a missing folder is missing")
        }
        let file = folder.appendingPathComponent("file.wav")
        try Data(count: 1).write(to: file)
        if case .missing = FolderWatcher.list(file.path, recursive: true) {} else { Issue.record("a file is no folder") }
        if case .failed = FolderWatcher.list(locked.path, recursive: true) {} else { Issue.record("no permission is retried") }
    }
}
