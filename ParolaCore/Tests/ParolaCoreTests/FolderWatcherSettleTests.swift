import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher settle rule", .tags(.fileSystem))
struct FolderWatcherSettleTests {
    private typealias Fixture = WatchedFolderFixture

    private func makeWatcher(_ folder: URL, clock: FixedClock, scheduler: ManualScheduler, collected: CollectedURLs) -> FolderWatcher {
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    private func append(_ bytes: Int, to url: URL, modified: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: bytes))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func size(_ url: URL) throws -> Int64 {
        try Int64(#require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    @Test("a writer that pauses mid-file arrives once, with the whole file")
    func pausedWriterArrivesWhenDone() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let recording = folder.appendingPathComponent("interview.wav")
        try Fixture.writeSettled(recording, clock: clock, bytes: 1000)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 2)
        #expect(collected.snapshot().isEmpty, "two quiet checks are not three")

        try append(1000, to: recording, modified: clock.start.addingTimeInterval(-9))
        try await scheduler.advance(ticks: 2)
        #expect(collected.snapshot().isEmpty, "the pause ended, so the count started over")

        try await scheduler.advanceAndWait()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["interview.wav"])
        #expect(await watcher.baseline()?.entries.map(\.size) == [2000])
        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(collected.snapshot().count == 1)
    }

    @Test("a file that grows soon after it arrived arrives again once it settles")
    func changeAfterArrivalIsOfferedAgain() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let copy = folder.appendingPathComponent("lecture.m4a")
        try Fixture.writeSettled(copy, clock: clock, bytes: 1000)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        #expect(collected.snapshot().count == 1)

        try append(3000, to: copy, modified: clock.start.addingTimeInterval(-5))
        try await scheduler.advanceAndWait()
        #expect(Fixture.names(await watcher.pendingPaths) == ["lecture.m4a"])
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["lecture.m4a", "lecture.m4a"])
        #expect(try size(copy) == 4000)
    }

    @Test("an edit long after a file arrived is not a new arrival")
    func lateEditIsNotAnArrival() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let file = folder.appendingPathComponent("memo.m4a")
        try Fixture.writeSettled(file, clock: clock, bytes: 1000)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)

        try append(500, to: file, modified: clock.start.addingTimeInterval(3600))
        try await scheduler.advance(ticks: 3)
        await watcher.checkForNewFiles()
        #expect(await watcher.pendingPaths.isEmpty)
        #expect(await watcher.baseline()?.entries.map(\.size) == [1500])
        await watcher.stop()
        #expect(collected.snapshot().count == 1)
    }

    @Test("a file Finder is still copying waits until Finder is done")
    func finderBusyFileWaits() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let copying = folder.appendingPathComponent("talk.mov")
        let busy = Date(timeIntervalSince1970: -753_578_704)
        try Fixture.writeSettled(copying, clock: clock)
        try FileManager.default.setAttributes([.creationDate: busy], ofItemAtPath: copying.path)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 4)
        #expect(collected.snapshot().isEmpty)

        try FileManager.default.setAttributes([.creationDate: clock.start.addingTimeInterval(-60)], ofItemAtPath: copying.path)
        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["talk.mov"])
    }

    @Test("an arrival that changed while the watcher was stopped is offered again; an older file is not")
    func changeWhileStoppedIsOfferedAgain() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let old = folder.appendingPathComponent("old.m4a")
        try Fixture.writeSettled(old, clock: clock)

        let collected = CollectedURLs()
        let first = ManualScheduler()
        let before = makeWatcher(folder, clock: clock, scheduler: first, collected: collected)
        await before.start()
        let arrival = folder.appendingPathComponent("arrival.wav")
        try Fixture.writeSettled(arrival, clock: clock)
        await before.checkForNewFiles()
        try await first.advance(ticks: 3)
        let saved = try #require(await before.baseline())
        await before.stop()
        #expect(saved.entries.first { $0.path == "arrival.wav" }?.emittedAt == clock.start)
        #expect(saved.entries.first { $0.path == "old.m4a" }?.emittedAt == nil)

        try append(2000, to: arrival, modified: clock.start.addingTimeInterval(-2))
        try append(2000, to: old, modified: clock.start.addingTimeInterval(-2))
        let second = ManualScheduler()
        let after = makeWatcher(folder, clock: clock, scheduler: second, collected: collected)
        await after.start(baseline: saved)
        #expect(Fixture.names(await after.pendingPaths) == ["arrival.wav"])
        try await second.advance(ticks: 3)
        await after.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["arrival.wav", "arrival.wav"])
    }

    @Test("the settle rule: three steady checks, a date older than one interval, no placeholder, no Finder copy")
    func settleRule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let options = FolderWatcher.Options(settledInterval: .seconds(1), stableChecks: 3)
        let old = now.addingTimeInterval(-30)
        let steady = FolderWatcher.SettleObservation(size: 10, modified: old, created: old, isDataless: false)
        func verdict(_ observation: FolderWatcher.SettleObservation, checks: Int, previous: (Int64, Date) = (10, old)) -> (FolderWatcher.SettleVerdict, Int) {
            var count = checks
            let result = FolderWatcher.settle(observation, after: previous, checks: &count, now: now, options: options)
            return (result, count)
        }

        #expect(verdict(steady, checks: 1) == (.wait, 2))
        #expect(verdict(steady, checks: 2) == (.arrive, 3))
        #expect(verdict(steady, checks: 2, previous: (9, old)) == (.wait, 1))

        var placeholder = steady
        placeholder.isDataless = true
        #expect(verdict(placeholder, checks: 2) == (.download, 0))

        var empty = steady
        empty.size = 0
        #expect(verdict(empty, checks: 2, previous: (0, old)) == (.hold, 0))

        var copying = steady
        copying.created = Date(timeIntervalSince1970: -753_578_704)
        #expect(verdict(copying, checks: 2) == (.hold, 0))

        var fresh = steady
        fresh.modified = now.addingTimeInterval(-0.5)
        #expect(verdict(fresh, checks: 2, previous: (10, fresh.modified)) == (.wait, 3))
    }

    @Test("a file Finder is still copying is checked less and less often, and whether it is a cloud file is asked once")
    func waitingFileBacksOff() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let lookups = CallCounter()
        let scheduler = ManualScheduler()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .seconds(1), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        options.cloud.isUbiquitous = { _ in
            lookups.increment()
            return false
        }
        let watcher = FolderWatcher(folderURL: folder, options: options) { _ in }
        await watcher.start()

        let copying = folder.appendingPathComponent("talk.mov")
        try Fixture.writeSettled(copying, clock: clock)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: -753_578_704)], ofItemAtPath: copying.path)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 8)
        await watcher.stop()

        let intervals = await scheduler.intervals.map { $0.components.seconds }
        #expect(intervals == [1, 2, 3, 5, 9, 17, 33, 33, 33])
        #expect(lookups.count == 1)
    }

    @Test("a new file is checked on the next tick even while another file waits out a long backoff")
    func newFileDoesNotWaitOutABackoff() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let scheduler = ManualScheduler()
        let collected = CollectedURLs()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .seconds(1), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        let watcher = FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
        await watcher.start()

        let copying = folder.appendingPathComponent("talk.mov")
        try Fixture.writeSettled(copying, clock: clock)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: -753_578_704)], ofItemAtPath: copying.path)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 6)
        #expect(await scheduler.intervals.last == .seconds(33))

        try Fixture.writeSettled(folder.appendingPathComponent("voice-memo.m4a"), clock: clock)
        await watcher.checkForNewFiles()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let parked = await scheduler.parkedCount
            let last = await scheduler.intervals.last
            if parked == 1, last == .seconds(1) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scheduler.intervals.last == .seconds(1))
        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["voice-memo.m4a"])
    }

    private final class Placeholder: Sendable {
        private let downloaded = OSAllocatedUnfairLock(initialState: false)
        let reads = CallCounter()
        let requests = CallCounter()
        var isDownloaded: Bool { downloaded.withLock { $0 } }
        func finish() { downloaded.withLock { $0 = true } }
    }

    private func placeholderWatcher(
        _ folder: URL, clock: FixedClock, scheduler: ManualScheduler, placeholder: Placeholder,
        readFails: Bool, collected: CollectedURLs
    ) -> FolderWatcher {
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        options.placeholderChecks = 2
        options.cloud = FolderWatcher.CloudProbe(
            isUbiquitous: { _ in true },
            isDownloaded: { _ in placeholder.isDownloaded },
            requestDownload: { _ in placeholder.requests.increment() },
            materialize: { _ in
                placeholder.reads.increment()
                struct Offline: Error {}
                if readFails { throw Offline() }
                placeholder.finish()
            }
        )
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    private func waitFor(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test("a cloud placeholder that doesn't download on request is read to make it download, then arrives")
    func stuckPlaceholderIsRead() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let placeholder = Placeholder()
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = placeholderWatcher(
            folder, clock: clock, scheduler: scheduler, placeholder: placeholder, readFails: false, collected: collected
        )
        await watcher.start()
        try Fixture.writeSettled(folder.appendingPathComponent("online-only.m4a"), clock: clock)
        await watcher.checkForNewFiles()

        try await scheduler.advance(ticks: 2)
        #expect(placeholder.requests.count == 1)
        #expect(await waitFor { placeholder.reads.count == 1 })
        #expect(collected.snapshot().isEmpty)

        try await scheduler.advance(ticks: 3)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["online-only.m4a"])
        #expect(placeholder.reads.count == 1)
    }

    @Test("stuck placeholders are read two at a time")
    func placeholderReadsAreLimited() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let reads = ReadGate()
        let scheduler = ManualScheduler()
        var options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        options.observesFileSystem = false
        options.placeholderChecks = 1
        options.cloud = FolderWatcher.CloudProbe(
            isUbiquitous: { _ in true },
            isDownloaded: { _ in false },
            requestDownload: { _ in },
            materialize: { _ in reads.read() }
        )
        let watcher = FolderWatcher(folderURL: folder, options: options) { _ in }
        await watcher.start()
        for index in 1...5 {
            try Fixture.writeSettled(folder.appendingPathComponent("online-only-\(index).m4a"), clock: clock)
        }
        await watcher.checkForNewFiles()
        try await scheduler.advanceAndWait()

        #expect(await waitFor { reads.active == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.most == 2)
        reads.open()
        #expect(await waitFor { reads.finished == 5 })
        #expect(reads.most == 2)
        await watcher.stop()
    }

    @Test("a placeholder whose read fails is handed over as it is rather than held forever")
    func unreadablePlaceholderArrivesAnyway() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let placeholder = Placeholder()
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = placeholderWatcher(
            folder, clock: clock, scheduler: scheduler, placeholder: placeholder, readFails: true, collected: collected
        )
        await watcher.start()
        try Fixture.writeSettled(folder.appendingPathComponent("offline.m4a"), clock: clock)
        await watcher.checkForNewFiles()

        try await scheduler.advance(ticks: 2)
        #expect(await waitFor { !collected.snapshot().isEmpty })
        #expect(await watcher.pendingPaths.isEmpty)
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["offline.m4a"])
    }
}

final class ReadGate: Sendable {
    private struct State {
        var active = 0
        var most = 0
        var finished = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)

    var active: Int { state.withLock { $0.active } }
    var most: Int { state.withLock { $0.most } }
    var finished: Int { state.withLock { $0.finished } }

    func read() {
        state.withLock {
            $0.active += 1
            $0.most = max($0.most, $0.active)
        }
        gate.wait()
        state.withLock {
            $0.active -= 1
            $0.finished += 1
        }
    }

    func open() {
        for _ in 0..<5 { gate.signal() }
    }
}

final class CallCounter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    func increment() { storage.withLock { $0 += 1 } }
    var count: Int { storage.withLock { $0 } }
}
